module Api
  module V1
    class PdfAnalysisSerializer
      def self.format_response(extraction_results, logs, source_url)
        {
          metadata: {
            source_url: source_url,
            analyzed_at: Time.current.iso8601,
            total_links: extraction_results[:links].size,
            pdf_reader_pages: extraction_results[:pdf_reader_text].size,
            poppler_pages: extraction_results[:poppler_text].size
          },
          links: format_links(extraction_results[:links]),
          text_extraction: {
            pdf_reader: format_text_extraction(extraction_results[:pdf_reader_text]),
            poppler: format_text_extraction(extraction_results[:poppler_text])
          },
          analysis_logs: format_logs(logs)
        }
      end

      private

      def self.format_links(links)
        links.map do |link|
          {
            page: link[:page],
            type: link[:type],
            uri: link[:uri],
            rect: link[:rect]
          }.compact
        end
      end

      def self.format_text_extraction(pages)
        pages.map do |page|
          {
            page: page[:page],
            content: page[:content],
            characters: page[:content].to_s.length
          }
        end
      end

      def self.format_logs(logs)
        logs.map do |log|
          {
            timestamp: log[:timestamp],
            level: log[:level],
            message: log[:message]
          }
        end
      end
    end
  end
end 