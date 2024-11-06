require 'open-uri'
require 'tempfile'

module Api
  module V1
    class PdfsController < ApplicationController
      include PdfExtractable
      
      skip_before_action :verify_authenticity_token
      
      def analyze
        unless params[:pdf_url].present?
          return render json: { error: 'PDF URL is required' }, status: :bad_request
        end

        begin
          # For Google Drive URLs, convert to direct download link
          pdf_url = convert_google_drive_url(params[:pdf_url])
          
          # Download the PDF from the URL
          pdf_tempfile = download_pdf(pdf_url)
          
          # Initialize logs array
          @analysis_logs = []
          
          # Process the PDF
          extraction_results = extract_pdf_links(pdf_tempfile.path)
          
          # Prepare the response
          response = {
            links: extraction_results[:links],
            pdf_reader_text: extraction_results[:pdf_reader_text],
            poppler_text: extraction_results[:poppler_text],
            analysis_logs: @analysis_logs,
            metadata: {
              source_url: params[:pdf_url],
              analyzed_at: Time.current,
              total_links: extraction_results[:links].size,
              pdf_reader_pages: extraction_results[:pdf_reader_text]&.size,
              poppler_pages: extraction_results[:poppler_text]&.size
            }
          }
          
          render json: response, status: :ok
          
        rescue OpenURI::HTTPError => e
          render json: { error: "Failed to download PDF: #{e.message}" }, status: :bad_request
        rescue => e
          render json: { 
            error: "Error processing PDF: #{e.message}",
            logs: @analysis_logs
          }, status: :unprocessable_entity
        ensure
          # Clean up temporary file
          pdf_tempfile&.close
          pdf_tempfile&.unlink
        end
      end

      private

      def convert_google_drive_url(url)
        return url unless url.include?('drive.google.com')
        
        # Extract file ID from Google Drive URL
        if url =~ /\/d\/(.*?)\/view/
          file_id = $1
          "https://drive.google.com/uc?export=download&id=#{file_id}"
        else
          url
        end
      end

      def download_pdf(url)
        log_message("Downloading PDF from: #{url}")
        
        tempfile = Tempfile.new(['downloaded_pdf', '.pdf'])
        download_result = URI.parse(url).open(
          'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
        )
        
        # Check content type if available
        content_type = download_result.content_type
        if content_type && content_type != 'application/pdf'
          tempfile.close
          tempfile.unlink
          raise "URL does not point to a PDF file (content type: #{content_type})"
        end
        
        IO.copy_stream(download_result, tempfile.path)
        log_message("PDF downloaded successfully")
        
        tempfile
      end

      def log_message(message, level = :info)
        timestamp = Time.current.strftime('%H:%M:%S')
        @analysis_logs ||= []
        @analysis_logs << {
          timestamp: timestamp,
          level: level,
          message: message
        }
        
        Rails.logger.send(level, "PDF Analysis: #{message}")
      end
    end
  end
end 