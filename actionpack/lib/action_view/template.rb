require 'active_support/core_ext/array/wrap'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/object/try'
require 'active_support/core_ext/kernel/singleton_class'

module ActionView
  # = Action View Template
  class Template
    extend ActiveSupport::Autoload

    # === Encodings in ActionView::Template
    #
    # ActionView::Template is one of a few sources of potential
    # encoding issues in Rails. This is because the source for
    # templates are usually read from disk, and Ruby (like most
    # encoding-aware programming languages) assumes that the
    # String retrieved through File IO is encoded in the
    # <tt>default_external</tt> encoding. In Rails, the default
    # <tt>default_external</tt> encoding is UTF-8.
    #
    # As a result, if a user saves their template as ISO-8859-1
    # (for instance, using a non-Unicode-aware text editor),
    # and uses characters outside of the ASCII range, their
    # users will see diamonds with question marks in them in
    # the browser.
    #
    # For the rest of this documentation, when we say "UTF-8",
    # we mean "UTF-8 or whatever the default_internal encoding
    # is set to". By default, it will be UTF-8.
    #
    # To mitigate this problem, we use a few strategies:
    # 1. If the source is not valid UTF-8, we raise an exception
    #    when the template is compiled to alert the user
    #    to the problem.
    # 2. The user can specify the encoding using Ruby-style
    #    encoding comments in any template engine. If such
    #    a comment is supplied, Rails will apply that encoding
    #    to the resulting compiled source returned by the
    #    template handler.
    # 3. In all cases, we transcode the resulting String to
    #    the UTF-8.
    #
    # This means that other parts of Rails can always assume
    # that templates are encoded in UTF-8, even if the original
    # source of the template was not UTF-8.
    #
    # From a user's perspective, the easiest thing to do is
    # to save your templates as UTF-8. If you do this, you
    # do not need to do anything else for things to "just work".
    #
    # === Instructions for template handlers
    #
    # The easiest thing for you to do is to simply ignore
    # encodings. Rails will hand you the template source
    # as the default_internal (generally UTF-8), raising
    # an exception for the user before sending the template
    # to you if it could not determine the original encoding.
    #
    # For the greatest simplicity, you can support only
    # UTF-8 as the <tt>default_internal</tt>. This means
    # that from the perspective of your handler, the
    # entire pipeline is just UTF-8.
    #
    # === Advanced: Handlers with alternate metadata sources
    #
    # If you want to provide an alternate mechanism for
    # specifying encodings (like ERB does via <%# encoding: ... %>),
    # you may indicate that you will handle encodings yourself
    # by implementing <tt>self.handles_encoding?</tt>
    # on your handler.
    #
    # If you do, Rails will not try to encode the String
    # into the default_internal, passing you the unaltered
    # bytes tagged with the assumed encoding (from
    # default_external).
    #
    # In this case, make sure you return a String from
    # your handler encoded in the default_internal. Since
    # you are handling out-of-band metadata, you are
    # also responsible for alerting the user to any
    # problems with converting the user's data to
    # the default_internal.
    #
    # To do so, simply raise the raise WrongEncodingError
    # as follows:
    #
    #     raise WrongEncodingError.new(
    #       problematic_string,
    #       expected_encoding
    #     )

    eager_autoload do
      autoload :Error
      autoload :Handler
      autoload :Handlers
      autoload :Text
    end

    extend Template::Handlers

    attr_accessor :locals, :formats, :virtual_path

    attr_reader :source, :identifier, :handler, :original_encoding, :updated_at

    # This finalizer is needed (and exactly with a proc inside another proc)
    # otherwise templates leak in development.
    Finalizer = proc do |method_name, mod|
      proc do
        mod.module_eval do
          remove_possible_method method_name
        end
      end
    end

    def initialize(source, identifier, handler, details)
      format = details[:format] || (handler.default_format if handler.respond_to?(:default_format))

      @source            = source
      @identifier        = identifier
      @handler           = handler
      @compiled          = false
      @original_encoding = nil
      @locals            = details[:locals] || []
      @virtual_path      = details[:virtual_path]
      @updated_at        = details[:updated_at] || Time.now
      @formats           = Array.wrap(format).map(&:to_sym)
    end

    # Render a template. If the template was not compiled yet, it is done
    # exactly before rendering.
    #
    # This method is instrumented as "!render_template.action_view". Notice that
    # we use a bang in this instrumentation because you don't want to
    # consume this in production. This is only slow if it's being listened to.
    def render(view, locals, &block)
      old_template, view._template = view._template, self
      ActiveSupport::Notifications.instrument("!render_template.action_view", :virtual_path => @virtual_path) do
        compile!(view)
        view.send(method_name, locals, &block)
      end
    rescue Exception => e
      handle_render_error(view, e)
    ensure
      view._template = old_template
    end

    def mime_type
      @mime_type ||= Mime::Type.lookup_by_extension(@formats.first.to_s) if @formats.first
    end

    # Receives a view object and return a template similar to self by using @virtual_path.
    #
    # This method is useful if you have a template object but it does not contain its source
    # anymore since it was already compiled. In such cases, all you need to do is to call
    # refresh passing in the view object.
    #
    # Notice this method raises an error if the template to be refreshed does not have a
    # virtual path set (true just for inline templates).
    def refresh(view)
      raise "A template needs to have a virtual path in order to be refreshed" unless @virtual_path
      lookup  = view.lookup_context
      pieces  = @virtual_path.split("/")
      name    = pieces.pop
      partial = !!name.sub!(/^_/, "")
      lookup.disable_cache do
        lookup.find_template(name, pieces.join('/'), partial, @locals)
      end
    end

    # Expires this template by setting his updated_at date to Jan 1st, 1970.
    def expire!
      @updated_at = Time.utc(1970)
    end

    # Receives a view context and renders a template exactly like self by using
    # the @virtual_path. It raises an error if no @virtual_path was given.
    def rerender(view)
      raise "A template needs to have a virtual path in order to be rerendered" unless @virtual_path
      name = @virtual_path.dup
      if name.sub!(/(^|\/)_([^\/]*)$/, '\1\2')
        view.render :partial => name
      else
        view.render :template => @virtual_path
      end
    end

    # Used to store template data by template handlers.
    def data
      @data ||= {}
    end

    def inspect
      @inspect ||=
        if defined?(Rails.root)
          identifier.sub("#{Rails.root}/", '')
        else
          identifier
        end
    end

    protected

      # Compile a template. This method ensures a template is compiled
      # just once and removes the source after it is compiled.
      def compile!(view) #:nodoc:
        return if @compiled

        if view.is_a?(ActionView::CompiledTemplates)
          mod = ActionView::CompiledTemplates
        else
          mod = view.singleton_class
        end

        compile(view, mod)

        # Just discard the source if we have a virtual path. This
        # means we can get the template back.
        @source = nil if @virtual_path
        @compiled = true
      end

      # Among other things, this method is responsible for properly setting
      # the encoding of the source. Until this point, we assume that the
      # source is BINARY data. If no additional information is supplied,
      # we assume the encoding is the same as Encoding.default_external.
      #
      # The user can also specify the encoding via a comment on the first
      # line of the template (# encoding: NAME-OF-ENCODING). This will work
      # with any template engine, as we process out the encoding comment
      # before passing the source on to the template engine, leaving a
      # blank line in its stead.
      #
      # If the template engine handles encodings, we send the encoded
      # String to the engine without further processing. This allows
      # the template engine to support additional mechanisms for
      # specifying the encoding. For instance, ERB supports <%# encoding: %>
      #
      # Otherwise, after we figure out the correct encoding, we then
      # encode the source into Encoding.default_internal. In general,
      # this means that templates will be UTF-8 inside of Rails,
      # regardless of the original source encoding.
      def compile(view, mod) #:nodoc:
        method_name = self.method_name

        if source.encoding_aware?
          # Look for # encoding: *. If we find one, we'll encode the
          # String in that encoding, otherwise, we'll use the
          # default external encoding.
          if source.sub!(/\A#{ENCODING_FLAG}/, '')
            encoding = magic_encoding = $1
          else
            encoding = Encoding.default_external
          end

          # Tag the source with the default external encoding
          # or the encoding specified in the file
          source.force_encoding(encoding)

          # If the user didn't specify an encoding, and the handler
          # handles encodings, we simply pass the String as is to
          # the handler (with the default_external tag)
          if !magic_encoding && @handler.respond_to?(:handles_encoding?) && @handler.handles_encoding?
            source
          # Otherwise, if the String is valid in the encoding,
          # encode immediately to default_internal. This means
          # that if a handler doesn't handle encodings, it will
          # always get Strings in the default_internal
          elsif source.valid_encoding?
            source.encode!
          # Otherwise, since the String is invalid in the encoding
          # specified, raise an exception
          else
            raise WrongEncodingError.new(source, encoding)
          end
        end

        arity = @handler.respond_to?(:arity) ? @handler.arity : @handler.method(:call).arity
        code  = arity == 1 ? @handler.call(self) : @handler.call(self, view)

        # Make sure that the resulting String to be evalled is in the
        # encoding of the code
        source = <<-end_src
          def #{method_name}(local_assigns)
            _old_output_buffer = @output_buffer;#{locals_code};#{code}
          ensure
            @output_buffer = _old_output_buffer
          end
        end_src

        if source.encoding_aware?
          # Make sure the source is in the encoding of the returned code
          source.force_encoding(code.encoding)

          # In case we get back a String from a handler that is not in
          # BINARY or the default_internal, encode it to the default_internal
          source.encode!

          # Now, validate that the source we got back from the template
          # handler is valid in the default_internal. This is for handlers
          # that handle encoding but screw up
          unless source.valid_encoding?
            raise WrongEncodingError.new(@source, Encoding.default_internal)
          end
        end

        begin
          mod.module_eval(source, identifier, 0)
          ObjectSpace.define_finalizer(self, Finalizer[method_name, mod])
        rescue Exception => e # errors from template code
          if logger = (view && view.logger)
            logger.debug "ERROR: compiling #{method_name} RAISED #{e}"
            logger.debug "Function body: #{source}"
            logger.debug "Backtrace: #{e.backtrace.join("\n")}"
          end

          raise ActionView::Template::Error.new(self, {}, e)
        end
      end

      def handle_render_error(view, e) #:nodoc:
        if e.is_a?(Template::Error)
          e.sub_template_of(self)
          raise e
        else
          assigns  = view.respond_to?(:assigns) ? view.assigns : {}
          template = @virtual_path ? refresh(view) : self
          raise Template::Error.new(template, assigns, e)
        end
      end

      def locals_code #:nodoc:
        @locals.map { |key| "#{key} = local_assigns[:#{key}];" }.join
      end

      def method_name #:nodoc:
        @method_name ||= "_#{identifier_method_name}__#{@identifier.hash}_#{__id__}".gsub('-', "_")
      end

      def identifier_method_name #:nodoc:
        inspect.gsub(/[^a-z_]/, '_')
      end
  end
end
