module PdfExtractable
  extend ActiveSupport::Concern

  def extract_pdf_links(pdf_path)
    require 'pdf-reader'
    require 'uri'
    
    reader = PDF::Reader.new(pdf_path)
    all_links = []
    pdf_reader_text = []
    poppler_text = []

    reader.pages.each_with_index do |page, page_num|
      log_message("Processing page #{page_num + 1}")
      
      begin
        # Extract text using pdf-reader
        text = page.text
        pdf_reader_text << {
          page: page_num + 1,
          content: text
        }
        
        log_message("Extracted #{text.length} characters from page #{page_num + 1}")
        
        if text.empty?
          log_message("No text extracted from page #{page_num + 1}", :warn)
          next
        end

        # Debug: Show first 100 characters of extracted text
        log_message("Sample text: #{text[0..100]}")
        
        # Look for URLs and email addresses with improved pattern matching
        urls = text.scan(%r{
          (?:https?://|www\.)[^\s<>"\{\}\|\\\^\[\]`\s]+|  # Web URLs
          [a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,} # Email addresses
        }x)
        
        if urls.any?
          log_message("Found #{urls.length} potential URLs in text")
          urls.each { |url| log_message("Potential URL found: #{url}") }
        end

        urls.each do |url|
          url = url.strip.gsub(/[.,;:]$/, '')
          next unless url =~ URI::regexp(['http', 'https', 'mailto']) || 
                      url.include?('www.') || 
                      url.match?(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/)
          
          link_data = {
            page: page_num + 1,
            type: 'text',
            uri: if url.include?('@')
                  "mailto:#{url}"
                elsif url.start_with?('www.')
                  "http://#{url}"
                else
                  url
                end
          }
          all_links << link_data
          log_message("Added text link: #{link_data[:uri]}")
        end

        # Also look for LinkedIn-style URLs that might be split across lines
        linkedin_matches = text.scan(/linkedin\.com\/(?:in|company)\/[^\s\/]+(?:\/[^\s\/]+)?/)
        linkedin_matches.each do |match|
          link_data = {
            page: page_num + 1,
            type: 'linkedin',
            uri: "https://www.#{match}"
          }
          all_links << link_data
          log_message("Added LinkedIn link: #{link_data[:uri]}")
        end

        # Look for GitHub URLs
        github_matches = text.scan(/github\.com\/[^\s\/]+(?:\/[^\s\/]+)?/)
        github_matches.each do |match|
          link_data = {
            page: page_num + 1,
            type: 'github',
            uri: "https://www.#{match}"
          }
          all_links << link_data
          log_message("Added GitHub link: #{link_data[:uri]}")
        end

      rescue => e
        log_message("Error processing page #{page_num + 1}: #{e.message}", :error)
        log_message("Error details: #{e.backtrace.first(5).join("\n")}", :error)
      end
    end

    # Also try to extract any PDF annotations (clickable links)
    begin
      reader.objects.each do |id, obj|
        next unless obj.is_a?(Hash) && obj[:Type] == :Annot && obj[:Subtype] == :Link
      
        if obj[:A] && obj[:A][:URI]
          link_data = {
            page: 1, # Note: PDF::Reader makes it harder to determine the page number for annotations
            type: 'annotation',
            uri: obj[:A][:URI]
          }
          all_links << link_data
          log_message("Added annotation link: #{link_data[:uri]}")
        end
      end
    rescue => e
      log_message("Error extracting annotations: #{e.message}", :error)
    end

    # Extract text using Poppler if available
    begin
      require 'poppler'
      doc = Poppler::Document.new(pdf_path)
      doc.each_with_index do |page, page_num|
        poppler_text << {
          page: page_num + 1,
          content: page.get_text
        }
      end
    rescue LoadError => e
      log_message("Poppler extraction skipped: #{e.message}", :warn)
    rescue => e
      log_message("Error in Poppler extraction: #{e.message}", :error)
    end

    log_message("Analysis complete. Total links found: #{all_links.length}")
    
    if all_links.empty?
      log_message("No links were found. Possible reasons:", :warn)
      log_message("1. The PDF doesn't contain any clickable links or URLs", :warn)
      log_message("2. The URLs might be formatted in an unexpected way", :warn)
      log_message("3. The URLs might be split across lines", :warn)
    end
    
    {
      links: all_links,
      pdf_reader_text: pdf_reader_text,
      poppler_text: poppler_text
    }
  end
end 