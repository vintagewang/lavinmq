module AvalancheMQ
  abstract class Exchange
    getter name, durable, auto_delete, internal, arguments, bindings

    def initialize(@vhost : VHost, @name : String, @durable : Bool,
                   @auto_delete : Bool, @internal : Bool,
                   @arguments = Hash(String, AMQP::Field).new )
      @bindings = Hash(Tuple(String, Hash(String, AMQP::Field)?), Set(String))
        .new { |h, k| h[k] = Set(String).new }
    end

    def to_json(builder : JSON::Builder)
      {
        name: @name, type: type, durable: @durable, auto_delete: @auto_delete,
        internal: @internal, arguments: @arguments, vhost: @vhost.name,
        bindings: @bindings
      }.to_json(builder)
    end

    def self.make(vhost, name, type, durable, auto_delete, internal, arguments)
      case type
      when "direct"
        DirectExchange.new(vhost, name, durable, auto_delete, internal, arguments)
      when "fanout"
        FanoutExchange.new(vhost, name, durable, auto_delete, internal, arguments)
      when "topic"
        TopicExchange.new(vhost, name, durable, auto_delete, internal, arguments)
      when "headers"
        HeadersExchange.new(vhost, name, durable, auto_delete, internal, arguments)
      else raise "Cannot make exchange type #{type}"
      end
    end

    abstract def type : String
    abstract def queues_matching(routing_key : String, headers : Hash(String, AMQP::Field)) : Set(String)
    abstract def bind(queue : String, binding_key : String, arguments : Hash(String, AMQP::Field)?)
    abstract def unbind(queue : String, binding_key : String, arguments : Hash(String, AMQP::Field)?)
  end

  class DirectExchange < Exchange
    def type
      "direct"
    end

    def bind(queue_name, binding_key, arguments = nil)
      @bindings[{ binding_key, nil }] << queue_name
    end

    def unbind(queue_name, binding_key, arguments = nil)
      @bindings[{ binding_key, nil }].delete queue_name
    end

    def queues_matching(routing_key, headers = nil)
      @bindings[{ routing_key, nil }]
    end
  end

  class FanoutExchange < Exchange
    def type
      "fanout"
    end

    def bind(queue_name, binding_key, arguments = nil)
      @bindings[{ "", nil }] << queue_name
    end

    def unbind(queue_name, binding_key, arguments = nil)
      @bindings[{ "", nil }].delete queue_name
    end

    def queues_matching(routing_key, headers = nil)
      @bindings[{ "", nil }]
    end
  end

  class TopicExchange < Exchange
    def type
      "topic"
    end

    def bind(queue_name, binding_key, arguments = nil)
      @bindings[{ binding_key, nil }] << queue_name
    end

    def unbind(queue_name, binding_key, arguments = nil)
      @bindings[{ binding_key, nil }].delete queue_name
    end

    def queues_matching(routing_key, headers = nil) : Set(String)
      rk_parts = routing_key.split(".")
      s = Set(String).new
      @bindings.each do |bt, q|
        ok = false
        bk_parts = bt[0].not_nil!.split(".")
        bk_parts.each_with_index do |part, i|
          if part == "#"
            ok = true
            break
          end
          if part == "*" || part == rk_parts[i]
            if bk_parts.size == i + 1 && rk_parts.size > i + 1
              ok = false
            else
              ok = true
            end
            next
          else
            ok = false
            break
          end
        end
        s.concat(q) if ok
      end
      s
    end
  end

  class HeadersExchange < Exchange
    def type
      "headers"
    end

    def bind(queue_name, binding_key, arguments)
      args = @arguments.merge(arguments)
      @vhost.log.debug("Binding #{queue_name} with #{args}")
      unless (arguments.has_key?("x-match") && args.size >= 2) || args.size == 1
        raise ArgumentError.new("Arguments required")
      end
      @bindings[{ "", args }] << queue_name
    end

    def unbind(queue_name, binding_key, arguments)
      @bindings.delete({ "", arguments })
    end

    def queues_matching(routing_key, headers) : Set(String)
      matches = Set(String).new
      return matches unless headers
      @bindings.each do |bt, queues|
        args = bt[1].not_nil!
        case args["x-match"]
        when "any"
          if headers.any? { |k, v| k != "x-match" && args.has_key?(k) && args[k] == v }
            matches.concat(queues)
          end
        else
          if headers.all? { |k, v| args.has_key?(k) && args[k] == v }
            matches.concat(queues)
          end
        end
      end
      matches
    end
  end
end
