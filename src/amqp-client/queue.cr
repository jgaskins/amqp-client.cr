require "./channel"

class AMQP::Client
  class Queue
    getter name

    def initialize(@channel : Channel, @name : String)
    end

    def bind(exchange : String, routing_key : String, no_wait = false, args = Arguments.new)
      @channel.queue_bind(@name, exchange, routing_key, no_wait, args)
      self
    end

    def unbind(exchange : String, routing_key : String, args = Arguments.new)
      @channel.queue_unbind(@name, exchange, routing_key, args)
      self
    end

    def publish(message, mandatory = false, immediate = false, props = Properties.new)
      @channel.basic_publish(message, "", @name, mandatory, immediate, props)
    end

    def publish_confirm(message, mandatory = false, immediate = false, props = Properties.new)
      @channel.basic_publish_confirm(message, "", @name, mandatory, immediate, props)
    end

    def get(no_ack = true)
      @channel.basic_get(@name, no_ack)
    end

    def subscribe(tag = "", no_ack = true, exclusive = false,
                  args = Arguments.new, &blk : Message -> Nil)
      @channel.basic_consume(@name, tag, no_ack, exclusive, args, &blk)
    end

    def unsubscribe(consumer_tag, no_wait = false)
      @channel.basic_cancel(consumer_tag, no_wait)
    end

    def purge
      @channel.queue_purge(@name)
    end

    def delete(if_unused = false, if_empty = false)
      @channel.queue_delete(@name, if_unused, if_empty)
    end
  end
end
