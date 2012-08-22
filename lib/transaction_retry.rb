require "active_record/errors"
require "active_support/concern"
require "active_support/core_ext/integer/inflections"

module TransactionRetry
  require "transaction_retry/version"

  extend ActiveSupport::Concern

  TRANSACTION_RETRY_DEFAULT_RETRIES = [1, 2, 4].freeze
  TRANSACTION_RETRY_ERRORS = {
    /Deadlock found when trying to get lock/ => [:retry],
    /Lock wait timeout exceeded/ => [:retry],
    /Lost connection to MySQL server during query/ => [:sleep, :reconnect, :retry],
    /MySQL server has gone away/ => [:sleep, :reconnect, :retry],
    /Query execution was interrupted/ => :retry,
    /The MySQL server is running with the --read-only option so it cannot execute this statement/ => [:reconnect, :retry]
  }.freeze

  included do
    mattr_accessor :transaction_errors, :transaction_retries

    self.transaction_errors = TRANSACTION_RETRY_ERRORS.dup
    self.transaction_retries = TRANSACTION_RETRY_DEFAULT_RETRIES.dup

    class << self
      alias_method :transaction_without_retry, :transaction
      alias_method :transaction, :transaction_with_retry
    end
  end

  module ClassMethods
    def transaction_with_retry(*args, &block)
      tries = 0

      begin
        transaction_without_retry(*args, &block)
      rescue ActiveRecord::StatementInvalid => error
        found, actions = transaction_errors.detect { |regex, action| regex =~ error.message }
        raise unless found
        raise if connection.open_transactions != 0
        raise if tries >= transaction_retries.count

        actions = Array(actions)
        delay = transaction_retries[tries]
        tries += 1

        if logger
          message = "Transaction failed to commit: '#{error.message}'. "
          message << actions.map do |action|
            case action
            when :sleep
              "sleeping for #{delay}s"
            when :reconnect
              "reconnecting"
            when :retry
              "retrying"
            end
          end.join(", ").capitalize
          message << " for the #{tries.ordinalize} time"
          logger.warn(message)
        end

        sleep(delay) if actions.include?(:sleep)
        if actions.include?(:reconnect)
          clear_active_connections!
          establish_connection
        end
        retry if actions.include?(:retry)
      end
    end
  end
end
