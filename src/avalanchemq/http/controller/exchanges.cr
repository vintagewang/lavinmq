require "uri"
require "../controller"
require "../resource_helper"

module AvalancheMQ
  class ExchangesController < Controller
    include ResourceHelper

    private def register_routes
      get "/api/exchanges" do |context, _params|
        @amqp_server.vhosts.flat_map { |v| v.exchanges.values }.to_json(context.response)
        context
      end

      get "/api/exchanges/:vhost" do |context, params|
        with_vhost(context, params) do |vhost|
          @amqp_server.vhosts[vhost].exchanges.values.to_json(context.response)
        end
      end

      get "/api/exchanges/:vhost/:name" do |context, params|
        with_vhost(context, params) do |vhost|
          name = params["name"]
          user = user(context)
          e = @amqp_server.vhosts[vhost].exchanges[name]?
          not_found(context, "Exchange #{name} does not exist") unless e
          e.to_json(context.response)
        end
      end

      put "/api/exchanges/:vhost/:name" do |context, params|
        with_vhost(context, params) do |vhost|
          user = user(context)
          name = params["name"]
          unless user.can_config?(vhost, name)
            access_refused(context, "User doesn't have permissions to declare exchange '#{name}'")
          end
          body = parse_body(context)
          type = body["type"]?.try &.as_s
          bad_request(context, "Field 'type' is required") unless type
          durable = body["durable"]?.try(&.as_bool?) || false
          auto_delete = body["auto_delete"]?.try(&.as_bool?) || false
          internal = body["internal"]?.try(&.as_bool?) || false
          arguments = parse_arguments(body)
          e = @amqp_server.vhosts[vhost].exchanges[name]?
          if e
            unless e.match?(type, durable, auto_delete, internal, arguments)
              bad_request(context, "Existing exchange declared with other arguments arg")
            end
            context.response.status_code = 200
          elsif name.starts_with? "amq."
            bad_request(context, "Not allowed to use the amq. prefix")
          else
            @amqp_server.vhosts[vhost]
              .declare_exchange(name, type, durable, auto_delete, internal, arguments)
            context.response.status_code = 201
          end
        end
      end

      delete "/api/exchanges/:vhost/:name" do |context, params|
        with_exchange(context, params) do |e|
          user = user(context)
          unless user.can_config?(e.vhost.name, e.name)
            access_refused(context, "User doesn't have permissions to delete exchange '#{e.name}'")
          end
          if context.request.query_params["if-unused"]? == "true"
            in_use = e.bindings.size > 0
            unless in_use
              destinations = e.vhost.exchanges.values.flat_map(&.bindings.values.flat_map(&.to_a))
              in_use = destinations.includes?(e)
            end
            bad_request(context, "Exchange #{e.name} in vhost #{e.vhost.name} in use") if in_use
          end
          e.delete
          context.response.status_code = 204
        end
      end

      get "/api/exchanges/:vhost/:name/bindings/source" do |context, params|
        with_exchange(context, params) do |e|
          e.bindings_details.to_json(context.response)
        end
      end

      get "/api/exchanges/:vhost/:name/bindings/destination" do |context, params|
        with_exchange(context, params) do |exchange|
          all_bindings = exchange.vhost.exchanges.values.flat_map(&.bindings_details)
          all_bindings.select { |b| b[:destination] == exchange.name }.to_json(context.response)
        end
      end

      post "/api/exchanges/:vhost/:name/publish" do |context, params|
        with_exchange(context, params) do |e|
          body = parse_body(context)
          properties = body["properties"]?
          routing_key = body["routing_key"]?.try(&.as_s)
          payload = body["payload"]?.try(&.as_s)
          payload_encoding = body["payload_encoding"]?.try(&.as_s)
          unless properties && routing_key && payload && payload_encoding
            bad_request(context, "Fields 'properties', 'routing_key', 'payload' and 'payload_encoding' are required")
          end
          case payload_encoding
          when "string"
            content = payload
          when "base64"
            content = Base64.decode(payload)
          else
            bad_request(context, "Unknown payload_encoding #{payload_encoding}")
          end
          size = content.bytesize.to_u64
          msg = Message.new(Time.utc_now.epoch_ms,
                            e.name,
                            routing_key,
                            AMQP::Properties.from_json(properties),
                            size,
                            content.to_slice)
          @log.debug { "Post to exchange=#{e.name} on vhost=#{e.vhost.name} with routing_key=#{routing_key} payload_encoding=#{payload_encoding} properties=#{properties} size=#{size}" }
          ok = e.vhost.publish(msg)
          { routed: ok }.to_json(context.response)
        end
      end
    end

    private def with_exchange(context, params)
      with_vhost(context, params) do |vhost|
        name = params["name"]
        e = @amqp_server.vhosts[vhost].exchanges[name]
        not_found(context, "Exchange #{name} does not exist") unless e
        yield e
      end
    end
  end
end
