class PdfsController < ApplicationController
  # Define log_message at the top of the class
  def log_message(message, level = :info)
    @analysis_logs ||= []
    timestamp = Time.current.strftime("%H:%M:%S")
    @analysis_logs << {
      timestamp: timestamp,
      level: level,
      message: message.to_s[0..200] # Limit message length
    }
    Rails.logger.send(level, message)
  end

  def show
    # You might want to store PDF analyses in your database
    # For now, we'll use a flash message to demonstrate
    if @links = session[:last_analysis]
      render 'show'
    else
      redirect_to new_pdf_path, notice: 'Please upload a PDF to analyze'
    end
  end

  def new
    # Display the upload form
  end

  def analyze_links
    @analysis_logs = []
    
    if params[:pdf].nil?
      flash[:error] = "Please select a PDF file"
      return redirect_to new_pdf_path
    end

    begin
      log_message("Processing PDF file: #{params[:pdf].original_filename}")
      extraction_results = extract_pdf_links(params[:pdf].tempfile.path)
      
      # Store analysis ID in session
      analysis_id = SecureRandom.hex(8)
      
      # Save detailed data to temporary file
      save_analysis_data(analysis_id, {
        links: extraction_results[:links],
        pdf_reader_text: extraction_results[:pdf_reader_text],
        poppler_text: extraction_results[:poppler_text],
        logs: @analysis_logs,
        filename: params[:pdf].original_filename,
        timestamp: Time.current.to_s
      })
      
      session[:analysis_id] = analysis_id
      redirect_to analysis_result_pdfs_path
    rescue => e
      log_message("Error analyzing PDF: #{e.message}", :error)
      flash[:error] = "Error analyzing PDF: #{e.message}"
      redirect_to new_pdf_path
    end
  end

  def analysis_result
    analysis_id = session[:analysis_id]
    
    unless analysis_id
      flash[:error] = "No analysis data found"
      return redirect_to new_pdf_path
    end

    begin
      @analysis_data = load_analysis_data(analysis_id)
      
      # Debug logging
      Rails.logger.debug "Loaded analysis data: #{@analysis_data.keys}"
      Rails.logger.debug "PDF Reader text pages: #{@analysis_data['pdf_reader_text']&.size}"
      Rails.logger.debug "Poppler text pages: #{@analysis_data['poppler_text']&.size}"
      
      unless @analysis_data
        flash[:error] = "Analysis data not found"
        return redirect_to new_pdf_path
      end
    rescue => e
      Rails.logger.error "Error loading analysis data: #{e.message}"
      flash[:error] = "Error loading analysis data"
      redirect_to new_pdf_path
    end
  end

  private

  def extract_pdf_text(pdf_path)
    require 'pdf-reader'
    require 'poppler'
    
    log_message("Starting PDF extraction with PDF::Reader")
    pdf_reader_text = extract_with_pdf_reader(pdf_path)
    log_message("PDF::Reader extracted #{pdf_reader_text.sum { |p| p[:content].to_s.length }} characters")
    
    log_message("Starting PDF extraction with Poppler") 
    poppler_text = extract_with_poppler(pdf_path)
    log_message("Poppler extracted #{poppler_text.sum { |p| p[:content].to_s.length }} characters")

    # Add debug logging for the text content
    pdf_reader_text.each do |page|
      log_message("=== Page #{page[:page]} Content Preview ===")
      log_message(page[:content][0..200]) # First 200 characters
      if contains_profile_keywords?(page[:content])
        log_message("Found profile-related keywords on page #{page[:page]}")
      end
    end

    {
      pdf_reader_text: pdf_reader_text,
      poppler_text: poppler_text
    }
  end

  def extract_pdf_links(pdf_path)
    require 'pdf-reader'
    require 'uri'
    require 'poppler'
    
    # Extract text using both methods
    log_message("Starting PDF extraction with PDF::Reader")
    pdf_reader_text = extract_with_pdf_reader(pdf_path)
    log_message("PDF::Reader extracted #{pdf_reader_text.sum { |p| p[:content].to_s.length }} characters")
    
    log_message("Starting PDF extraction with Poppler")
    poppler_text = extract_with_poppler(pdf_path)
    log_message("Poppler extracted #{poppler_text.sum { |p| p[:content].to_s.length }} characters")

    # Extract links using the working method
    reader = PDF::Reader.new(pdf_path)
    all_links = []

    reader.pages.each_with_index do |page, page_num|
      log_message("Processing page #{page_num + 1}")
      
      begin
        # Extract text using pdf-reader
        text = page.text
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
  rescue => e
    log_message("PDF extraction error: #{e.full_message}", :error)
    raise "Error processing PDF: #{e.message}"
  end

  def extract_with_pdf_reader(pdf_path)
    text_by_page = []
    reader = PDF::Reader.new(pdf_path)
    
    reader.pages.each_with_index do |page, page_num|
      begin
        text = page.text.to_s
        log_message("PDF::Reader - Page #{page_num + 1}: extracted #{text.length} characters")
        
        text_by_page << {
          page: page_num + 1,
          content: text
        }
      rescue => e
        log_message("PDF::Reader error on page #{page_num + 1}: #{e.message}", :warn)
        text_by_page << {
          page: page_num + 1,
          content: "",
          error: e.message
        }
      end
    end
    
    text_by_page
  end

  def extract_with_poppler(pdf_path)
    text_by_page = []
    
    begin
      doc = Poppler::Document.new(pdf_path)
      
      doc.each_with_index do |page, page_num|
        begin
          text = page.get_text
          log_message("Poppler - Page #{page_num + 1}: extracted #{text.length} characters")
          
          text_by_page << {
            page: page_num + 1,
            content: text
          }
        rescue => e
          log_message("Poppler error on page #{page_num + 1}: #{e.message}", :warn)
          text_by_page << {
            page: page_num + 1,
            content: "",
            error: e.message
          }
        end
      end
    rescue => e
      log_message("Poppler initialization error: #{e.message}", :error)
      text_by_page << {
        page: 1,
        content: "",
        error: "Failed to initialize Poppler: #{e.message}"
      }
    end
    
    text_by_page
  end

  def save_analysis_data(id, data)
    file_path = Rails.root.join('tmp', 'analysis', "#{id}.json")
    FileUtils.mkdir_p(File.dirname(file_path))
    File.write(file_path, data.to_json)
  end

  def load_analysis_data(id)
    file_path = Rails.root.join('tmp', 'analysis', "#{id}.json")
    return nil unless File.exist?(file_path)
    
    data = JSON.parse(File.read(file_path))
    # Delete the file after reading to clean up
    File.delete(file_path)
    data
  rescue
    nil
  end

  def extract_from_raw_content(page)
    text = ""
    return text unless page.raw_content

    begin
      page.raw_content.split(/\[(.*?)\]TJ/).each do |chunk|
        # Convert hex characters to regular text
        chunk.gsub!(/\<([0-9A-Fa-f]+)\>/) { [$1].pack("H*") }
        # Remove PDF operators and other non-text elements
        chunk.gsub!(/[\/\\\(\)\[\]\{\}]/, " ")
        text << chunk
      end
    rescue => e
      log_message("Error in raw content extraction: #{e.message}", :warn)
    end
    
    handle_encoding(text)
  end

  def clean_text(text)
    return "" if text.nil? || text.empty?
    
    handle_encoding(
      text
        .gsub(/\s+/, ' ')                    # Normalize whitespace
        .gsub(/([.!?])\s*([A-Z])/, '\1 \2')  # Ensure space after sentences
        .gsub(/([a-z])([A-Z])/, '\1 \2')     # Add space between camelCase
        .gsub(/\b([A-Z]+)\b(?=[a-z])/, ' \1') # Space before acronyms
        .gsub(/\s+/, ' ')                    # Final whitespace cleanup
        .gsub(/(\d+)\.(\d+)/, '\1. \2')      # Fix decimal numbers
        .strip
    )
  end

  def handle_encoding(text)
    # Try UTF-8 first
    text.encode('UTF-8', 'UTF-8', invalid: :replace, undef: :replace, replace: '')
  rescue
    begin
      # Try Windows-1252 (common in PDFs)
      text.encode('UTF-8', 'Windows-1252', invalid: :replace, undef: :replace, replace: '')
    rescue
      begin
        # Try ISO-8859-1
        text.encode('UTF-8', 'ISO-8859-1', invalid: :replace, undef: :replace, replace: '')
      rescue
        # Last resort: remove any non-ASCII characters
        text.encode('UTF-8', 'ASCII', invalid: :replace, undef: :replace, replace: '')
      end
    end
  end

  def extract_links_from_text(text, page_num, all_links)
    return if text.nil? || text.empty?

    # Extract LinkedIn URLs (more permissive pattern)
    linkedin_matches = text.scan(%r{
      (?:https?://)?
      (?:www\.)?
      linkedin\.com/
      (?:in|company|profile)/
      [^\s<>(),]+
    }x)
    
    linkedin_matches.each do |match|
      match = clean_url(match)
      log_message("Found LinkedIn URL: #{match}")
      all_links << {
        page: page_num,
        type: 'linkedin',
        uri: ensure_https(match)
      }
    end

    # Extract GitHub URLs (more permissive pattern)
    github_matches = text.scan(%r{
      (?:https?://)?
      (?:www\.)?
      github\.com/
      [^\s<>(),]+
    }x)
    
    github_matches.each do |match|
      match = clean_url(match)
      log_message("Found GitHub URL: #{match}")
      all_links << {
        page: page_num,
        type: 'github',
        uri: ensure_https(match)
      }
    end

    # Extract StackOverflow URLs
    stackoverflow_matches = text.scan(%r{
      (?:https?://)?
      (?:www\.)?
      stackoverflow\.com/
      (?:users|questions|answers|a|q)/
      [^\s<>(),]+
    }x)
    
    stackoverflow_matches.each do |match|
      match = clean_url(match)
      log_message("Found StackOverflow URL: #{match}")
      all_links << {
        page: page_num,
        type: 'stackoverflow',
        uri: ensure_https(match)
      }
    end

    # Extract email addresses (improved pattern)
    emails = text.scan(/[\w\.-]+@[\w\.-]+\.\w+/)
    emails.each do |email|
      email = email.strip
      log_message("Found email: #{email}")
      all_links << {
        page: page_num,
        type: 'email',
        uri: "mailto:#{email}"
      }
    end

    # Extract other URLs
    urls = text.scan(%r{
      (?:https?://)?
      (?:www\.)?
      [a-zA-Z0-9-]+
      (?:\.[a-zA-Z0-9-]+)*
      \.[a-zA-Z]{2,}
      (?:/[^\s<>(),]*)?
    }x)
    
    urls.each do |url|
      url = clean_url(url)
      next if url.match?(/\.(png|jpg|jpeg|gif|pdf|doc|docx)$/i) # Skip file extensions
      next if url.match?(/linkedin\.com|github\.com|stackoverflow\.com/i) # Skip already processed domains
      
      log_message("Found URL: #{url}")
      all_links << {
        page: page_num,
        type: 'url',
        uri: ensure_https(url)
      }
    end
  end

  def clean_url(url)
    url.strip
         .gsub(/[.,;:)]$/, '') # Remove trailing punctuation
         .gsub(/[<>()]/, '')   # Remove brackets/parentheses
         .split(/[\s\n\r]+/)   # Split on whitespace
         .first                # Take first part
         .to_s
  end

  def ensure_https(url)
    return url if url.start_with?('http')
    return "https://#{url}" if url.include?('.')
    url
  end

  # Also add this helper method to check if text contains specific keywords
  def contains_profile_keywords?(text)
    keywords = [
      'github', 'linkedin', 'stack overflow', 'stackoverflow',
      'profile', 'connect', 'follow me', 'portfolio',
      'projects', 'repositories', 'contributions'
    ]
    
    keywords.any? { |keyword| text.downcase.include?(keyword) }
  end

  def categorize_link(uri)
    case uri.downcase
    when /linkedin\.com/ then 'linkedin'
    when /github\.com/ then 'github'
    when /stackoverflow\.com/ then 'stackoverflow'
    when /mailto:/ then 'email'
    else 'url'
    end
  end
end
