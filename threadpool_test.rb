require 'java'
require 'open-uri'
require 'threadpool'
require 'http_connection_pool'

$STATE = java.util.concurrent.ConcurrentHashMap.new

def dummy_long_process
  delay = 7 + (rand * 10).to_i
  sleep delay
end

def long_process(dummy = false, client_side_loadbalancing = false)
  dummy_long_process and return if dummy
  
  host = 'localhost'
  if client_side_loadbalancing
    port = "300#{1 + (rand * 3).to_i}"
  else
    port = "3000"
  end
  @http_pool.open_url :method => 'GET', :request_uri => "http://#{host}:#{port}/"
end

invoker = Thread.new do
  throughput = 160
  threadpool_size = 2000

  http_pool_size = 340
  @http_pool = HTTPConnectionPool.new 'localhost', 3000, http_pool_size

  $STATE['errors'] = java.util.concurrent.ConcurrentHashMap.new
  
  $STATE['errors']['connection'] = 0
  $STATE['errors']['fatal'] = 0
  
  begin
    pool = java.util.concurrent.Executors.newFixedThreadPool(threadpool_size)
    loop do
      throughput.times do
        pool.execute do
          begin
            thread_id = "#{Time.now.to_i}#{Thread.current.inspect.split(':')[-1][0..9]}"
            $STATE[thread_id] ||= java.util.concurrent.ConcurrentHashMap.new
            value = long_process
            $STATE[thread_id]['value'] = value
          rescue Errno::ECONNREFUSED
            puts "Connection refused in thread: #{thread_id}, retrying"
            $STATE['errors']['connection'] += 1
            redo
          rescue Errno::EPIPE
            puts "Errno::EPIPE in thread: #{thread_id}, retrying"
            $STATE['errors']['connection'] += 1
            redo
          rescue
            print "Error in individual thread: #{thread_id}", $!, "\n"
            $STATE['errors']['fatal'] += 1
          end
        end
      end
      sleep 1
    end
  rescue
    p "Error in invoker: ", $!
  end
end

top = Thread.new do
  Thread.current.abort_on_exception = true
  
  poll_delay = 5
  
  total = 0
  finished = 0
  waiting = 0
  earlier_total = 0
  earlier_finished = 0
  
  loop do
    earlier_total = total
    earlier_finished = finished
    total = $STATE.size
    finished = $STATE.select { |key, stats| stats['value'] }.size
    waiting = total - finished
    
    unless total == 0
      print "",
        "T: ", total, " F: ", finished, " W: ", waiting,  
        " CE: ", $STATE['errors']['connection'], " FE: ", $STATE['errors']['fatal'],
        " IT (req/s): ", (total - earlier_total) / poll_delay, 
        " FT (req/s): ", (finished - earlier_finished) / poll_delay, "\n"
      puts @http_pool.stats
    end
    
    sleep poll_delay
  end
end

invoker.join



