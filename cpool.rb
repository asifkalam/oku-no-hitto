class CPool
  attr_accessor :host, :port, :verbose
  attr_reader :state
  def initialize host, port, max_size = 300, verbose = nil
    @pool = Queue.new
    @host, @port, @max_size, @verbose = host, port, max_size, verbose
    @state = java.util.concurrent.ConcurrentHashMap.new
    @state['num_conns'] = 0
    @state['granted'] = 0
    @state['rejected'] = 0
    @begin_time = Time.now
  end

  def get_conn
    begin
      c = @pool.pop(non_block=true)
    rescue ThreadError # queue empty
      if @state['num_conns'] < @max_size
        c = Net::HTTP.new @host, @port
        puts "Spawned new connection #{c.object_id}." if @verbose
        @state['num_conns'] += 1
      else
        @state['rejected'] += 1
        puts "Max. pool size #{@max_size} hit. Connection not granted." if @verbose
        return nil
      end
    end
    @state['granted'] += 1
    print_stats if @verbose
    puts "Granting connection #{c.object_id} from pool." if @verbose
    c
  end

  def put_conn conn
    if @pool.size < @max_size
      if conn.nil?
        @state['num_conns'] -= 1
      else
        @pool << conn
        puts "Connection #{conn.object_id} returned to pool." if @verbose
      end
    else
      puts "Max. pool size #{@max_size} hit. Connection #{conn.object_id} discarded." if @verbose
    end
    print_stats if @verbose
  end

  def print_stats
    puts "#{{:connections => @state['num_conns'],
    :in_use => @state['num_conns'] - @pool.size,
    :requests_granted => @state['granted'],
    :requests_rejected => @state['rejected'],
    :num_waiting => @pool.num_waiting,
    :rps => "%.2f"}.inspect}" % (@state['granted'] / (Time.now - @begin_time))
  end
end