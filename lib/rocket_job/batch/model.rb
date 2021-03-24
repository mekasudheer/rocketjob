require "active_support/concern"
module RocketJob
  module Batch
    # Model attributes
    module Model
      extend ActiveSupport::Concern

      included do
        #
        # User definable attributes
        #
        # The following attributes are set when the job is created

        # Number of records to include in each slice that is processed
        # Note:
        #   slice_size is only used by SlicedJob#upload & Sliced::Input#upload
        #   When slices are supplied directly, their size is not modified to match this number
        field :slice_size, type: Integer, default: 100, class_attribute: true, user_editable: true, copy_on_restart: true

        # Whether to store the results from this job
        field :collect_output, type: Mongoid::Boolean, default: false, class_attribute: true

        # Whether to retain nil results.
        #
        # Only applicable if `collect_output` is `true`
        # Set to `false` to prevent collecting output from the perform
        # method when it returns `nil`.
        field :collect_nil_output, type: Mongoid::Boolean, default: true, class_attribute: true

        # The file name of the uploaded file, if any.
        # Set by #upload if a file name was supplied, but can also be set explicitly.
        # May or may not include the fully qualified path name.
        field :upload_file_name, type: String

        # Compress data in flight and at rest in the database.
        # Often improves performance since data is smaller.
        # Can be overridden on a per category basis, see Categories.
        field :compress, type: Mongoid::Boolean, default: false, class_attribute: true

        # Encrypt and compress data in flight and at rest in the database.
        # Using the Symmetric Encryption Library encrypts data to keep it secure.
        # Compression is also turned on so that less data is encrypted which improves performance.
        # Can be overridden on a per category basis, see Categories.
        field :encrypt, type: Mongoid::Boolean, default: false, class_attribute: true

        #
        # Values that jobs can also update during processing
        #

        # Number of records in this job
        # Note:
        #   A record_count of nil means it has not been set and workers will
        #   _not_ complete the job when processing slices.
        #   This allows workers to start processing slices while slices are still
        #   being uploaded
        field :record_count, type: Integer

        #
        # Read-only attributes
        #

        # Breaks the :running state up into multiple sub-states:
        #   :running -> :before -> :processing -> :after -> :complete
        field :sub_state, type: Mongoid::StringifiedSymbol

        validates_presence_of :slice_size
      end

      # Returns [true|false] whether the slices for this job are encrypted
      def encrypted?
        encrypt == true
      end

      # Returns [true|false] whether the slices for this job are compressed
      def compressed?
        compress == true
      end

      # Returns [Integer] percent of records completed so far
      # Returns 0 if the total record count has not yet been set
      def percent_complete
        return 100 if completed?
        return 0 unless record_count.to_i.positive?

        # Approximate number of input records
        input_records = input.count.to_f * slice_size
        if input_records > record_count
          # Sanity check in case slice_size is not being adhered to
          99
        else
          ((1.0 - (input_records.to_f / record_count)) * 100).to_i
        end
      end

      # Returns [Hash] status of this job
      def status(time_zone = "Eastern Time (US & Canada)")
        h = {}
        if queued?
          h["queued_slices"] = input.queued.count
        elsif running? || paused? || failed?
          h["active_slices"] = worker_count
          h["failed_slices"] = input.failed.count
          h["queued_slices"] = input.queued.count
          # Very high level estimated time left
          if record_count && running? && record_count.positive?
            percent = percent_complete
            if percent >= 5
              secs                        = seconds.to_f
              h["est_remaining_duration"] = RocketJob.seconds_as_duration((((secs / percent) * 100) - secs))
            end
          end
        elsif completed?
          secs                  = seconds.to_f
          h["records_per_hour"] = ((record_count.to_f / secs) * 60 * 60).round if record_count&.positive? && (secs > 0.0)
        end
        h["output_slices"] = output.count if collect_output? && !completed?
        h.merge!(super(time_zone))
        h.delete("result")
        # Worker name should be retrieved from the slices when processing
        h.delete("worker_name") if sub_state == :processing
        h
      end

      # Returns [Array<String>] names of workers currently working this job.
      def worker_names
        return [] unless running?

        case sub_state
        when :before, :after
          [worker_name]
        when :processing
          input.running.collect(&:worker_name)
        else
          []
        end
      end

      # Returns [Integer] the number of workers currently working on this job.
      def worker_count
        return 0 unless running?
        # Cache the number of workers for 1 second.
        return @worker_count if @worker_count_last && (@worker_count_last == Time.now.to_i)

        @worker_count      =
          case sub_state
          when :before, :after
            1
          when :processing
            input.running.count
          else
            0
          end
        @worker_count_last = Time.now.to_i
        @worker_count
      end

      # Returns [true|false] whether to collect nil results from running this batch
      def collect_nil_output?
        collect_output? ? (collect_nil_output == true) : false
      end

      # Returns [true|false] whether to collect the results from running this batch
      def collect_output?
        collect_output == true
      end
    end
  end
end
