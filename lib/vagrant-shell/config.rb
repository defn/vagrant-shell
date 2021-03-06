require "vagrant"

module VagrantPlugins
  module Shell
    class Config < Vagrant.plugin("2", :config)
      # The access key ID for accessing cloud.
      #
      # @return [String]
      attr_accessor :access_key_id

      # The ID of the image to use.
      #
      # @return [String]
      attr_accessor :image

      # The availability zone to launch the instance into. If nil, it will
      # use the default for your account.
      #
      # @return [String]
      attr_accessor :availability_zone

      # The timeout to wait for an instance to become ready.
      #
      # @return [Fixnum]
      attr_accessor :instance_ready_timeout

      # The interval to wait for checking an instance's state.
      #
      # @return [Fixnum]
      attr_accessor :instance_check_interval

      # The type of instance to launch, such as "m3.medium"
      #
      # @return [String]
      attr_accessor :instance_type

      # The name of the cloud region in which to create the instance.
      #
      # @return [String]
      attr_accessor :region

      # The EC2 endpoint to connect to
      #
      # @return [String]
      attr_accessor :endpoint

      # The version of the cloud api to use
      #
      # @return [String]
      attr_accessor :version

      # The secret access key for accessing cloud.
      #
      # @return [String]
      attr_accessor :secret_access_key

      # The token associated with the key for accessing cloud.
      #
      # @return [String]
      attr_accessor :session_token

      # The env for the machine.
      #
      # @return [Hash<String, String>]
      attr_accessor :env

      def initialize(region_specific=false)
        @access_key_id             = UNSET_VALUE
        @secret_access_key         = UNSET_VALUE
        @session_token             = UNSET_VALUE

        @image                     = UNSET_VALUE
        @instance_type             = UNSET_VALUE
        @region                    = UNSET_VALUE
        @availability_zone         = UNSET_VALUE

        @instance_check_interval   = UNSET_VALUE
        @instance_ready_timeout    = UNSET_VALUE

        @endpoint                  = UNSET_VALUE
        @version                   = UNSET_VALUE

        @env                       = {}

        # Internal state (prefix with __ so they aren't automatically
        # merged)
        @__compiled_region_configs = {}
        @__finalized = false
        @__region_config = {}
        @__region_specific = region_specific
      end

      # Allows region-specific overrides of any of the settings on this
      # configuration object. This allows the user to override things like
      # image for regions. Example:
      #
      #     cloud.region_config "us-east-1" do |region|
      #       region.image = "id-12345678"
      #     end
      #
      # @param [String] region The region name to configure.
      # @param [Hash] attributes Direct attributes to set on the configuration
      #   as a shortcut instead of specifying a full block.
      # @yield [config] Yields a new cloud configuration.
      def region_config(region, attributes=nil, &block)
        # Append the block to the list of region configs for that region.
        # We'll evaluate these upon finalization.
        @__region_config[region] ||= []

        # Append a block that sets attributes if we got one
        if attributes
          attr_block = lambda do |config|
            config.set_options(attributes)
          end

          @__region_config[region] << attr_block
        end

        # Append a block if we got one
        @__region_config[region] << block if block_given?
      end

      #-------------------------------------------------------------------
      # Internal methods.
      #-------------------------------------------------------------------

      def merge(other)
        super.tap do |result|
          # Copy over the region specific flag. "True" is retained if either
          # has it.
          new_region_specific = other.instance_variable_get(:@__region_specific)
          result.instance_variable_set(
          :@__region_specific, new_region_specific || @__region_specific)

          # Go through all the region configs and prepend ours onto
          # theirs.
          new_region_config = other.instance_variable_get(:@__region_config)
          @__region_config.each do |key, value|
            new_region_config[key] ||= []
            new_region_config[key] = value + new_region_config[key]
          end

          # Set it
          result.instance_variable_set(:@__region_config, new_region_config)

          # Merge in the env
          result.env.merge!(self.env)
          result.env.merge!(other.env)
        end
      end

      def finalize!
        # Try to get access keys from standard cloud environment variables; they
        # will default to nil if the environment variables are not present.
        @access_key_id     = ENV['CLOUD_ACCESS_KEY'] if @access_key_id     == UNSET_VALUE
        @secret_access_key = ENV['CLOUD_SECRET_KEY'] if @secret_access_key == UNSET_VALUE
        @session_token     = ENV['CLOUD_SESSION_TOKEN'] if @session_token == UNSET_VALUE

        # image must be nil, since we can't default that
        @image = nil if @image == UNSET_VALUE

        # Set the default timeout for waiting for an instance to be ready
        @instance_ready_timeout = 120 if @instance_ready_timeout == UNSET_VALUE

        # Set the default interval to check instance state
        @instance_check_interval = 2 if @instance_check_interval == UNSET_VALUE

        # Default instance type is an m3.medium
        @instance_type = "m3.medium" if @instance_type == UNSET_VALUE

        # Default region is us-east-1. This is sensible because cloud
        # generally defaults to this as well.
        @region = "us-east-1" if @region == UNSET_VALUE
        @availability_zone = nil if @availability_zone == UNSET_VALUE
        @endpoint = nil if @endpoint == UNSET_VALUE
        @version = nil if @version == UNSET_VALUE

        # Compile our region specific configurations only within
        # NON-REGION-SPECIFIC configurations.
        if !@__region_specific
          @__region_config.each do |region, blocks|
            config = self.class.new(true).merge(self)

            # Execute the configuration for each block
            blocks.each { |b| b.call(config) }

            # The region name of the configuration always equals the
            # region config name:
            config.region = region

            # Finalize the configuration
            config.finalize!

            # Store it for retrieval
            @__compiled_region_configs[region] = config
          end
        end

        # Mark that we finalized
        @__finalized = true
      end

      def validate(machine)
        errors = _detected_errors

        errors << I18n.t("vagrant_shell.config.region_required") if @region.nil?

        if @region
          # Get the configuration for the region we're using and validate only
          # that region.
          config = get_region_config(@region)

          errors << I18n.t("vagrant_shell.config.access_key_id_required") if \
            config.access_key_id.nil?
          errors << I18n.t("vagrant_shell.config.secret_access_key_required") if \
            config.secret_access_key.nil?

          errors << I18n.t("vagrant_shell.config.image_required", :region => @region)  if config.image.nil?
        end

        { "Shell Provider" => errors }
      end

      # This gets the configuration for a specific region. It shouldn't
      # be called by the general public and is only used internally.
      def get_region_config(name)
        if !@__finalized
          raise "Configuration must be finalized before calling this method."
        end

        # Return the compiled region config
        @__compiled_region_configs[name] || self
      end
    end
  end
end
