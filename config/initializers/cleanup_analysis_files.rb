# Clean up old analysis files every hour
if defined?(Rails::Server)
  Thread.new do
    while true
      sleep 1.hour
      
      begin
        analysis_dir = Rails.root.join('tmp', 'analysis')
        next unless Dir.exist?(analysis_dir)
        
        Dir.glob(File.join(analysis_dir, '*.json')).each do |file|
          # Remove files older than 1 hour
          File.delete(file) if File.mtime(file) < 1.hour.ago
        end
      rescue => e
        Rails.logger.error "Error cleaning up analysis files: #{e.message}"
      end
    end
  end
end
