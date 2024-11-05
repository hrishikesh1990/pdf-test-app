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
      
      # Create a summary of links
      links_summary = extraction_results[:links].map { |link| {
        page: link[:page],
        uri: link[:uri]
      }}

      # Store analysis ID in session
      analysis_id = SecureRandom.hex(8)
      
      # Save detailed data to temporary file
      save_analysis_data(analysis_id, {
        links: extraction_results[:links],
        text: extraction_results[:text],
        logs: @analysis_logs,
        filename: params[:pdf].original_filename,
        timestamp: Time.current.to_s
      })
      
      # Store minimal data in session
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
      flash[:error] = "No analysis data found. Please upload a PDF."
      return redirect_to new_pdf_path
    end

    @analysis_data = load_analysis_data(analysis_id)
    
    unless @analysis_data
      flash[:error] = "Analysis data has expired. Please try again."
      return redirect_to new_pdf_path
    end

    render :analysis_result
  end

  private

  def extract_pdf_links(pdf_path)
    require 'pdf-reader'
    require 'uri'
    
    reader = PDF::Reader.new(pdf_path)
    all_links = []
    all_text = []

    reader.pages.each_with_index do |page, page_num|
      log_message("Processing page #{page_num + 1}")
      
      begin
        # Extract text using multiple methods and clean it
        text = extract_and_clean_text(page)
        log_message("Extracted #{text.length} characters from page #{page_num + 1}")
        
        # Store text with page number
        all_text << {
          page: page_num + 1,
          content: text
        }
        
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
            type: 'text',
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
            type: 'text',
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
    
    # Return both links and text
    {
      links: all_links,
      text: all_text
    }
  rescue => e
    log_message("PDF extraction error: #{e.message}", :error)
    raise "Error processing PDF: #{e.message}"
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

  def extract_and_clean_text(page)
    # Method 1: Standard text extraction
    standard_text = page.text

    # Method 2: Extract text using raw content stream
    raw_text = extract_from_raw_content(page)

    # Choose the better result or combine them
    text = choose_better_text(standard_text, raw_text)

    # Clean and format the text
    clean_text(text)
  end

  def extract_from_raw_content(page)
    text = ""
    return text unless page.raw_content

    # Process each text showing operation in the content stream
    page.raw_content.split(/\[(.*?)\]TJ/).each do |chunk|
      # Convert hex characters to regular text
      chunk.gsub!(/\<([0-9A-Fa-f]+)\>/) { [$1].pack("H*") }
      # Remove PDF operators and other non-text elements
      chunk.gsub!(/[\/\\\(\)\[\]\{\}]/, " ")
      text << chunk
    end
    text
  end

  def choose_better_text(text1, text2)
    # Choose the text that appears more properly formatted
    # This is a simple heuristic - you might want to adjust it
    score1 = text_quality_score(text1)
    score2 = text_quality_score(text2)
    
    score1 > score2 ? text1 : text2
  end

  def text_quality_score(text)
    return 0 if text.nil? || text.empty?
    
    score = 0
    # More spaces between words is usually better
    score += text.count(' ') * 2
    # More newlines usually indicates better paragraph separation
    score += text.count("\n")
    # Penalize runs of special characters
    score -= text.scan(/[^a-zA-Z0-9\s]{3,}/).count * 5
    # Penalize missing spaces after periods
    score -= text.scan(/\.[a-zA-Z]/).count * 3
    
    score
  end

  def clean_text(text)
    return "" if text.nil? || text.empty?
    
    text
      .gsub(/\s+/, ' ')                    # Normalize whitespace
      .gsub(/([.!?])\s*([A-Z])/, '\1 \2')  # Ensure space after sentences
      .gsub(/([a-z])([A-Z])/, '\1 \2')     # Add space between camelCase
      .gsub(/\b([A-Z]+)\b(?=[a-z])/, ' \1') # Space before acronyms
      .gsub(/\s+/, ' ')                    # Final whitespace cleanup
      .gsub(/(\d+)\.(\d+)/, '\1. \2')      # Fix decimal numbers
      .strip
  end
end
