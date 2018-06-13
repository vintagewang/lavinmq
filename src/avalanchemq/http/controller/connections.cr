require "uri"
require "../controller"

module AvalancheMQ
  module ConnectionsHelper
    private def connections(user : User)
      @amqp_server.connections.select { |c| can_access_connection?(c, user) }
    end

    private def can_access_connection?(c, user)
      c.user == user || user.tags.any? { |t| t.administrator? || t.monitoring? }
    end
  end

  class ConnectionsController < Controller
    include ConnectionsHelper

    private def register_routes
      get "/api/connections" do |context, _params|
        connections(user(context)).to_json(context.response)
        context
      end

      get "/api/vhosts/:vhost/connections" do |context, params|
        with_vhost(context, params) do |vhost|
          refuse_unless_management(context, user(context), vhost)
          @amqp_server.connections.select { |c| c.vhost.name == vhost }.to_json(context.response)
        end
      end

      get "/api/connections/:name" do |context, params|
        with_connection(context, params) do |connection|
          connection.to_json(context.response)
        end
      end

      delete "/api/connections/:name" do |context, params|
        with_connection(context, params) do |c|
          c.close(context.request.headers["X-Reason"]?)
          context.response.status_code = 204
        end
      end

      get "/api/connections/:name/channels" do |context, params|
        with_connection(context, params) do |connection|
          connection.channels.values.to_json(context.response)
        end
      end
    end

    private def with_connection(context, params)
      name = URI.unescape(params["name"])
      user = user(context)
      connection = @amqp_server.connections.find { |c| c.name == name }
      not_found(context, "Connection #{name} does not exist") unless connection
      access_refused(context) unless can_access_connection?(connection, user)
      yield connection
      context
    end
  end
end
