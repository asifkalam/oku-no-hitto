require 'net/https'
require 'active_support/core_ext/hash/reverse_merge'
require 'logger'

class HostChangedError < RuntimeError
end

class ConnectionNotGrantedError < RuntimeError
end

class MaxRetriesExceededError < RuntimeError
end

class HTTPConnectionPool
  attr_accessor :host, :port
  attr_reader :state

  def initialize host, port = nil, max_size = 300
    @host, @port, @max_size = host, port, max_size
    @pool                       = java.util.concurrent.LinkedBlockingQueue.new(max_size)
    @state                      = java.util.concurrent.ConcurrentHashMap.new
    @state['conns_alive']       = 0
    @state['conns_granted']     = 0
    @state['conns_not_granted'] = 0
    @begin_time                 = Time.now
#    @log                     = Logger.new "logs/#{File.basename(__FILE__)}.#{Process.pid}.log"
    @log                        = Logger.new STDOUT
    @log.level                  = Logger::INFO
  end

  def same_host_and_port? uri
    uri.relative? or (uri.host == @host and uri.port == @port)
  end

  def open_url options = {}
    options.reverse_merge! :method => 'GET', :request_uri => '/', :body => nil, :headers => nil, :retries => 3, :assert_same_host_and_port => true
    uri = URI::parse options[:request_uri]
    if options[:assert_same_host_and_port]
      raise HostChangedError unless same_host_and_port? uri
    end
    begin
      conn         = get_conn
      conn.use_ssl = 'https' == uri.scheme
      response     = if 'POST' == options[:method]
                       conn.post uri.path, options[:body], options[:headers]
                     else
                       request_string = "#{uri.path}#{'?' + uri.query if uri.query}"
                       conn.get request_string, options[:headers]
                     end
      put_conn conn
      response
    rescue => e
      @log.error e.inspect
      if options[:retries] > 0
        options[:retries] -= 1
        open_url options
      else
        @state['conns_alive'] -= 1
        raise
      end
    end
  end

  def stats
    {:conns_alive    => @state['conns_alive'],
     :conns_in_use   => @state['conns_alive'] - @pool.size,
     :max_pool_size  => @max_size,
     :conns_granted  => @state['conns_granted'],
     :conns_rejected => @state['conns_not_granted'],
     :rps            => "%.2f" % (@state['conns_granted'] / (Time.now - @begin_time))}.inspect
  end

  private

  def new_conn
    Net::HTTP.new @host, @port
  end

  def get_conn
    c = @pool.poll
    unless c
      if @state['conns_alive'] < @max_size
        c                     = new_conn
        @state['conns_alive'] += 1
        @log.debug "Spawned new connection #{c.object_id}."
      else
        @state['conns_not_granted'] += 1
        @log.error "Max. pool size #{@max_size} hit. Connection not granted."
        raise ConnectionNotGrantedError
      end
    end
    @state['conns_granted'] += 1
    @log.debug stats
    @log.debug "Granting connection #{c.object_id} from pool."
    c
  end

  def put_conn conn
    begin
      @pool.offer conn
      @log.debug "Connection #{conn.object_id} returned to pool."
    rescue java.lang.NullPointerException => e
      @log.error "#{e} nil Connection #{conn.object_id} discarded."
    rescue java.lang.IllegalStateException => e
      # close the connection and discard
      conn.finish
      @log.error "#{e} Max. pool size #{@max_size} hit. Connection #{conn.object_id} discarded."
    end
    @log.debug stats
  end
end