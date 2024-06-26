# frozen_string_literal: true

module RailsRouteChecker
  class LoadedApp
    def initialize
      app_base_path = Dir.pwd
      suppress_output do
        require_relative "#{app_base_path}/config/boot"
      end

      begin
        suppress_output do
          require_relative "#{Dir.pwd}/config/environment"
        end
      rescue Exception => e
        puts "Requiring your config/environment.rb file failed."
        puts "This means that something raised while trying to start Rails."
        puts ""
        puts e.backtrace
        raise(e)
      end

      suppress_output do
        @app = Rails.application
        @app.eager_load!
        Rails::Engine.subclasses.each(&:eager_load!)
      end
    end

    def routes
      return @routes if defined?(@routes)

      @routes = app.routes.routes.reject do |r|
        reject_route?(r)
      end.uniq

      return @routes unless app.config.respond_to?(:assets)

      use_spec = defined?(ActionDispatch::Journey::Route) || defined?(Journey::Route)
      @routes.reject do |route|
        path = use_spec ? route.path.spec.to_s : route.path
        path =~ /^#{app.config.assets.prefix}/
      end
    end

    def all_route_names
      @all_route_names ||= app.routes.routes.map(&:name).compact
    end

    def controller_information
      return @controller_information if @controller_information

      base_controllers_descendants = [ActionController::Base, ActionController::API].flat_map(&:descendants)

      @controller_information = base_controllers_descendants.map do |controller|
        next if controller.controller_path.nil? || controller.controller_path.start_with?('rails/')

        controller_helper_methods =
          if controller.respond_to?(:helpers)
            controller.helpers.methods.map(&:to_s)
          else
            []
          end

        [
          controller.controller_path,
          {
            helpers: controller_helper_methods,
            actions: controller.action_methods.to_a,
            instance_methods: instance_methods(controller),
            lookup_context: lookup_context(controller)
          }
        ]
      end.compact.to_h
    end

    private

    attr_reader :app

    def lookup_context(controller)
      return nil unless controller.instance_methods.include?(:default_render)

      ActionView::LookupContext.new(controller._view_paths, {}, controller._prefixes)
    end

    def instance_methods(controller)
      (controller.instance_methods.map(&:to_s) + controller.private_instance_methods.map(&:to_s)).compact.uniq
    end

    def suppress_output
      begin
        original_stderr = $stderr.clone
        original_stdout = $stdout.clone
        $stderr.reopen(File.new('/dev/null', 'w'))
        $stdout.reopen(File.new('/dev/null', 'w'))
        retval = yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        $stdout.reopen(original_stdout)
        $stderr.reopen(original_stderr)
        raise e
      ensure
        $stdout.reopen(original_stdout)
        $stderr.reopen(original_stderr)
      end
      retval
    end

    def reject_route?(route)
      return true if route.name.nil? && route.requirements.blank?
      return true if route.app.is_a?(ActionDispatch::Routing::Mapper::Constraints) &&
                     route.app.app.respond_to?(:call)
      return true if route.app.is_a?(ActionDispatch::Routing::Redirect)

      controller = route.requirements[:controller]
      action = route.requirements[:action]
      return true unless controller && action
      return true if controller.start_with?('rails/')

      false
    end
  end
end
