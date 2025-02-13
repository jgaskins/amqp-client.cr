require "socket"
require "openssl"
require "logger"
require "amq-protocol"
require "./channel"
require "./sparse_array"
require "../amqp-client"

abstract class OpenSSL::SSL::Socket
  def read_timeout=(read_timeout)
    io = @bio.io
    if io.responds_to? :read_timeout=
      io.read_timeout = read_timeout
    else
      raise NotImplementedError.new("#{io.class}#read_timeout=")
    end
  end

  def write_timeout=(write_timeout)
    io = @bio.io
    if io.responds_to? :write_timeout=
      io.write_timeout = write_timeout
    else
      raise NotImplementedError.new("#{io.class}#write_timeout=")
    end
  end
end

class AMQP::Client
  class Connection
    getter frame_max, log
    getter? closed = false

    def initialize(@io : UNIXSocket | TCPSocket | OpenSSL::SSL::Socket::Client,
                   @log : Logger, @channel_max : UInt16,
                   @frame_max : UInt32, @heartbeat : UInt16)
      spawn read_loop, name: "AMQP::Client#read_loop"
    end

    @channels = SparseArray(Channel).new

    def channel(id : UInt16? = nil)
      if id
        raise "channel_max reached" if @channel_max < id
        return @channels[id] if @channels.has_key? id
        ch = @channels[id] = Channel.new(self, id)
        return ch.open
      end
      1_u16.upto(@channel_max) do |i|
        next if @channels.has_key? i
        ch = @channels[i] = Channel.new(self, i)
        return ch.open
      end
      raise "channel_max reached"
    end

    def channel(&blk : Channel -> _)
      ch = channel
      yield ch
      ch.close
    end

    @on_close : Proc(UInt16, String, Nil)?

    def on_close(&blk : UInt16, String ->)
      @on_close = blk
    end

    private def read_loop
      loop do
        Frame.from_io(@io) do |f|
          @log.debug { "got #{f.inspect}" }
          case f
          when Frame::Connection::Close
            @log.info("Connection closed by server: #{f.inspect}") unless @on_close || @closed
            begin
              @on_close.try &.call(f.reply_code, f.reply_text)
            rescue ex
              @log.error "Uncaught exception in on_close block: #{ex.inspect_with_backtrace}"
            end
            write Frame::Connection::CloseOk.new
            next false
          when Frame::Connection::CloseOk
            next false
          when Frame::Connection::Blocked
            @log.info "Blocked by server, reason: #{f.reason}"
            @write_lock.lock
          when Frame::Connection::Unblocked
            @log.info "Unblocked by server"
            @write_lock.unlock
          when Frame::Heartbeat
            write f
          else
            if @channels.has_key? f.channel
              @channels[f.channel].incoming f
            else
              @log.error "Channel #{f.channel} not open for frame #{f.inspect}"
            end

            case f
            when Frame::Channel::Close,
                 Frame::Channel::CloseOk
              @channels.delete f.channel
            end
          end
          true
        end || break
      rescue ex : IO::Error | Errno
        break
      rescue ex
        @log.error "read_loop exception: #{ex.inspect}"
        break
      end
      @closed = true
      @io.close
    rescue ex : Errno
    ensure
      @channels.each_value &.cleanup
      @channels.clear
    end

    @write_lock = Mutex.new

    def with_lock(&blk : Connection -> Nil)
      @write_lock.synchronize do
        yield self
        @io.flush
      end
    end

    def write(frame, flush = true)
      return if @closed
      @io.write_bytes frame, ::IO::ByteFormat::NetworkEndian
      @io.flush if flush
      @log.debug { "sent #{frame.inspect}" }
    end

    def flush
      @io.flush
    end

    def close(msg = "Connection closed")
      @log.info("Closing connection")
      write Frame::Connection::Close.new(320_u16, msg, 0_u16, 0_u16)
      @closed = true
    rescue ex : Errno | IO::Error
      @log.info("Socket already closed, can't send close frame")
    end

    def self.start(io : UNIXSocket | TCPSocket | OpenSSL::SSL::Socket::Client, log,
                   user, password, vhost,
                   channel_max, frame_max, heartbeat)
      io.read_timeout = 15
      io.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
      io.flush
      Frame.from_io(io) { |f| f.as?(Frame::Connection::Start) || raise UnexpectedFrame.new(f) }

      props = Arguments.new
      props["product"] = "amqp-client.cr"
      props["platform"] = "Crystal"
      props["version"] = AMQP::Client::VERSION
      capabilities = Arguments.new
      capabilities["publisher_confirms"] = true
      capabilities["exchange_exchange_bindings"] = true
      capabilities["basic.nack"] = true
      capabilities["per_consumer_qos"] = true
      capabilities["authentication_failure_close"] = true
      capabilities["consumer_cancel_notify"] = true
      capabilities["connection.blocked"] = true
      props["capabilities"] = capabilities
      user = URI.unescape(user)
      password = URI.unescape(password)
      response = "\u0000#{user}\u0000#{password}"
      io.write_bytes(Frame::Connection::StartOk.new(props, "PLAIN", response, ""),
        IO::ByteFormat::NetworkEndian)
      io.flush
      tune = Frame.from_io(io) do |f|
        case f
        when Frame::Connection::Tune then next f
        when Frame::Connection::Close
          raise Connection::ClosedException.new(f.as(Frame::Connection::Close))
        else
          raise UnexpectedFrame.new(f)
        end
      end
      channel_max = tune.channel_max.zero? ? channel_max : tune.channel_max
      frame_max = tune.frame_max.zero? ? frame_max : tune.frame_max
      io.write_bytes Frame::Connection::TuneOk.new(channel_max: channel_max,
        frame_max: frame_max,
        heartbeat: heartbeat), IO::ByteFormat::NetworkEndian
      io.write_bytes Frame::Connection::Open.new(vhost), IO::ByteFormat::NetworkEndian
      io.flush
      Frame.from_io(io) do |f|
        case f
        when Frame::Connection::OpenOk then next
        when Frame::Connection::Close
          raise Connection::ClosedException.new(f.as(Frame::Connection::Close))
        else
          raise UnexpectedFrame.new(f)
        end
      end

      Connection.new(io, log, channel_max, frame_max, heartbeat)
    rescue ex : IO::EOFError
      raise Connection::ClosedException.new("Connection closed by server", ex)
    ensure
      io.read_timeout = nil
    end

    class ClosedException < Exception
      def initialize(message, cause)
        super(message, cause)
      end

      def initialize(close : Frame::Connection::Close)
        super("#{close.reply_code} - #{close.reply_text}")
      end
    end
  end
end
