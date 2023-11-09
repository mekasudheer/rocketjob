require "fileutils"
require "uri"

module RocketJob
  module Jobs
    # Job to upload a file into another job.
    #
    # Intended for use by DirmonJob to upload a file into a specified job.
    #
    # Can be used directly for any job class, as long as that job responds
    # to `#upload`.
    class UploadFileJob < RocketJob::Job
      self.priority = 30

      # Name of the job class to instantiate and upload the file into.
      field :job_class_name, type: String, user_editable: true

      # Properties to assign to the job when it is created.
      field :properties, type: Hash, default: {}, user_editable: true

      # File to upload
      field :upload_file_name, type: IOStreams::Path, user_editable: true

      # The original Input file name.
      # Used by #upload to extract the IOStreams when present.
      field :original_file_name, type: String, user_editable: true

      # Optionally set the job id for the downstream job
      # Useful when for example the archived file should contain the job id for the downstream job.
      field :job_id, type: BSON::ObjectId

      validates_presence_of :upload_file_name, :job_class_name
      validate :job_is_a_rocket_job
      validate :job_implements_upload
      validate :file_exists
      validate :job_has_properties

      # Create the job and upload the file into it.
      def perform
        job    = job_class.from_properties(properties)
        job.id = job_id if job_id
        upload_file(job)
        job.save!
      rescue Exception => e
        # Prevent partial uploads
        job&.cleanup! if job.respond_to?(:cleanup!)
        raise(e)
      end

      private

      def job_class
        @job_class ||= job_class_name.constantize
      rescue NameError
        nil
      end

      def upload_file(job)
        if job.respond_to?(:upload)
          # Return the database connection for this thread back to the connection pool
          # in case the upload takes a long time and the database connection expires.
          if defined?(ActiveRecord::Base)
            if ActiveRecord::Base.respond_to?(:connection_handler)
              # Rails 7
              ActiveRecord::Base.connection_handler.clear_active_connections!
            else
              ActiveRecord::Base.connection_pool.release_connection
            end
          end

          if original_file_name
            job.upload(upload_file_name, file_name: original_file_name)
          else
            job.upload(upload_file_name)
          end
        elsif job.respond_to?(:upload_file_name=)
          job.upload_file_name = upload_file_name
        elsif job.respond_to?(:full_file_name=)
          job.full_file_name = upload_file_name
        else
          raise(
            ArgumentError,
            "Model #{job_class_name} must implement '#upload', or have attribute 'upload_file_name' or 'full_file_name'"
          )
        end
      end

      # Validates job_class is a Rocket Job
      def job_is_a_rocket_job
        klass = job_class
        return if klass.nil? || klass.ancestors&.include?(RocketJob::Job)

        errors.add(:job_class_name, "Model #{job_class_name} must be defined and inherit from RocketJob::Job")
      end

      VALID_INSTANCE_METHODS = %i[upload upload_file_name= full_file_name=].freeze

      # Validates job_class is a Rocket Job
      def job_implements_upload
        klass = job_class
        return if klass.nil? || klass.instance_methods.any? { |m| VALID_INSTANCE_METHODS.include?(m) }

        errors.add(:job_class_name,
                   "#{job_class} must implement any one of: :#{VALID_INSTANCE_METHODS.join(' :')} instance methods")
      end

      def file_exists
        # Only check for file existence when it is a local file
        return unless upload_file_name.is_a?(IOStreams::Paths::File)
        return errors.add(:upload_file_name, "Upload file name can't be blank.") if upload_file_name.to_s == ""

        return if upload_file_name.exist?

        errors.add(:upload_file_name, "Upload file: #{upload_file_name} does not exist.")
      rescue NotImplementedError
        nil
      end

      def job_has_properties
        klass = job_class
        return unless klass

        properties.each_pair do |k, _v|
          next if klass.public_method_defined?("#{k}=".to_sym)

          if %i[output_categories input_categories].include?(k)
            category_class = k == :input_categories ? RocketJob::Category::Input : RocketJob::Category::Output
            properties[k].each do |category|
              category.each_pair do |key, _value|
                next if category_class.public_method_defined?("#{key}=".to_sym)

                errors.add(
                  :properties,
                  "Unknown Property in #{k}: Attempted to set a value for #{key}.#{k} which is not allowed on the job #{job_class_name}"
                )
              end
            end
            next
          end

          errors.add(
            :properties,
            "Unknown Property: Attempted to set a value for #{k.inspect} which is not allowed on the job #{job_class_name}"
          )
        end
      end
    end
  end
end
