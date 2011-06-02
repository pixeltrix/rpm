require 'fileutils'
module NewRelic
  class DataSerialization
    module ClassMethods
      # Check whether the store is too large, too old, or the
      # semaphore file is too old. If so, we should send the data
      # right away. If not, we presumably store it for later sending
      # (handled elsewhere)
      def should_send_data?
        # TODO get configuration from main control
        store_too_large? || store_too_old? || semaphore_too_old?
      rescue (ENV['CATCH_EXCEPTION'] ? Exception : Class.new) => e
        # This is not what we really should do here, but the fail-safe
        # behavior is to do what the older agent did: send data every
        # time we think we might want to send data.
        true
      end
      
      def read_and_write_to_file
        with_locked_store do |f|
          result = (yield get_data_from_file(f))
          f.rewind
          write_contents_nonblockingly(f, dump(result)) if result
        end
      end

      def update_last_sent!
        FileUtils.touch(semaphore_path)
      end
      
      private

      def store_too_large?
        size = File.size(file_path) > max_size
        NewRelic::Control.instance.log.debug("Store was oversize, sending data") if size
        size
      rescue Errno::ENOENT
        FileUtils.touch(file_path)
        retry
      end

      def store_too_old?
        age = (Time.now.to_i - File.mtime(file_path).to_i)
        NewRelic::Control.instance.log.debug("Store was #{age} seconds old, sending data") if age > 60
        age > 60
      rescue Errno::ENOENT
        FileUtils.touch(file_path)
        retry
      end

      def semaphore_too_old?
        age = (Time.now.to_i - File.mtime(semaphore_path).to_i)
        NewRelic::Control.instance.log.debug("Pid was #{age} seconds old, sending data") if age > 60
        age > 60
      rescue Errno::ENOENT
        FileUtils.touch(semaphore_path)
        retry
      end
        
      def with_locked_store
        File.open(file_path, File::RDWR | File::CREAT) do |f|
          f.flock(File::LOCK_EX)
          begin
            yield(f)
          ensure
            f.flock(File::LOCK_UN)
          end
        end
      rescue Exception => e
        puts e.inspect
      end

      def get_data_from_file(f)
        data = read_until_eof_error(f)
        result = load(data)
        f.truncate(0)
        result
      end

      def write_contents_nonblockingly(f, string)
        result = 0
        while(result < string.length)
          result += f.write_nonblock(string)
        end
      rescue Errno::EAGAIN, Errno::EINTR
        IO.select(nil, [f])
        retry
      end

      def read_until_eof_error(f)
        accumulator = ""
        while(true)
          accumulator << f.read_nonblock(10_000)
        end
      rescue Errno::EAGAIN, Errno::EINTR
        IO.select([f])
        retry
      rescue EOFError
        accumulator
      end
      
      def max_size
        10_000
      end

      def dump(object)
        Marshal.dump(object)
      end

      def load(dump)
        Marshal.load(dump)
      rescue ArgumentError => e
        nil
      end

      def truncate_file
        create_file_if_needed
        File.truncate(file_path, 0)
      end

      def file_path
        # TODO get configuration from main control
        './log/newrelic_agent_store.db'
      end

      def semaphore_path
        # TODO get configuration from main control
        './log/newrelic_agent_store.age'
      end
    end
    extend ClassMethods
  end
end
