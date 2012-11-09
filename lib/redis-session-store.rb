require 'action_controller/session/abstract_store'
require 'redis'

# Redis session storage for Rails, and for Rails only. Derived from
# the MemCacheStore code, simply dropping in Redis instead.
#
# Options:
#  :key     => Same as with the other cookie stores, key name
#  :secret  => Encryption secret for the key
#  :redis => {
#    :host    => Redis host name, default is localhost
#    :port    => Redis port, default is 6379
#    :db      => Database number, defaults to 0. Useful to separate your session storage from other data
#    :key_prefix  => Prefix for keys used in Redis, e.g. myapp-. Useful to separate session storage keys visibly from others
#    :expire_after => A number in seconds to set the timeout interval for the session. Will map directly to expiry in Redis
#  }
module ActionController
  module Session

    class RedisSessionStore < AbstractStore

      def initialize(app, options = {})
        super

        redis_options = options[:redis] || {}

        @default_options.merge!(:namespace => 'rack:session')
        @default_options.merge!(redis_options)
        @redis = Redis.new(redis_options)
      end

      # Overriding default AbstractStore#call in order to allow lazy sessions
      # when using the `expire_after` option. See https://rails.lighthouseapp.com/projects/8994/tickets/4450-expire_after-option-on-session-forces-session-creation-on-each-and-every-action
      def call(env)
        prepare!(env)
        response = @app.call(env)

        Rails.logger.info env['rack.session.options'].to_json

        session_data = env[ENV_SESSION_KEY]
        options = env[ENV_SESSION_OPTIONS_KEY]

        if !session_data.is_a?(AbstractStore::SessionHash) || session_data.loaded? # || options[:expire_after]
          request = ActionController::Request.new(env)

          return response if (options[:secure] && !request.ssl?)

          session_data.send(:load!) if session_data.is_a?(AbstractStore::SessionHash) && !session_data.loaded?

          sid = options[:id] || generate_sid

          unless set_session(env, sid, session_data.to_hash)
            return response
          end

          request_cookies = env["rack.request.cookie_hash"]

          if (request_cookies.nil? || request_cookies[@key] != sid) || options[:expire_after]
            cookie = {:value => sid}
            cookie[:expires] = Time.now + options[:expire_after] if options[:expire_after]
            Rack::Utils.set_cookie_header!(response[1], @key, cookie.merge(options))
          end
        end

        response
      end

      private
        def prefixed(sid)
          "#{@default_options[:key_prefix]}#{sid}"
        end

        def get_session(env, sid)
          sid ||= generate_sid
          begin
            data = @redis.get(prefixed(sid))
            session = data.nil? ? {} : Marshal.load(data)
          rescue Errno::ECONNREFUSED
            session = {}
          end
          [sid, session]
        end

        def set_session(env, sid, session_data)
          options = env['rack.session.options']
          expiry  = options[:expire_after] || nil
          if expiry
            @redis.setex(prefixed(sid), expiry, Marshal.dump(session_data))
          else
            @redis.set(prefixed(sid), Marshal.dump(session_data))
          end
          return true
        rescue Errno::ECONNREFUSED
          return false
        end

        def destroy(env)
          if env['rack.request.cookie_hash'] && env['rack.request.cookie_hash'][@key]
            @redis.del( prefixed(env['rack.request.cookie_hash'][@key]) )
          end
        rescue Errno::ECONNREFUSED
          Rails.logger.warn("RedisSessionStore#destroy: Connection to redis refused")
        end
    end


  end
end
