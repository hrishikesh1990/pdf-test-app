class PdfsController < ApplicationController
  # Define log_message at the top of the class
  def log_message(message, level = :info)
    @analysis_logs ||= []
    timestamp = Time.current.strftime("%H:%M:%S")
    @analysis_logs << {
      timestamp: timestamp,
      level: level,
      message: message
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
      @links = extract_pdf_links(params[:pdf].tempfile.path)
      
      session[:last_analysis] = {
        links: @links,
        logs: @analysis_logs,
        filename: params[:pdf].original_filename,
        timestamp: Time.current.to_s  # Store as string
      }
      
      redirect_to analysis_result_pdfs_path
    rescue => e
      log_message("Error analyzing PDF: #{e.message}", :error)
      flash[:error] = "Error analyzing PDF: #{e.message}"
      redirect_to new_pdf_path
    end
  end

  def analysis_result
    @analysis_data = session[:last_analysis]
    
    unless @analysis_data
      flash[:error] = "No analysis data found. Please upload a PDF."
      redirect_to new_pdf_path
    end
  end

  private

  def extract_pdf_links(pdf_path)
    require 'hexapdf'
    require 'uri'
    
    doc = HexaPDF::Document.open(pdf_path)
    all_links = []

    doc.pages.each_with_index do |page, page_num|
      log_message("Processing page #{page_num + 1}")
      
      # Method 1: Check for link annotations
      begin
        annotations = page[:Annots]&.value || []
        annotations = annotations.map { |annot| doc.wrap(annot) if annot }
        
        links = annotations.compact.select { |annot| 
          annot.type == :Link rescue false 
        }
        
        log_message("Found #{links.length} annotation links on page #{page_num + 1}")
        
        links.each do |link|
          begin
            uri = if link.action.nil?
                    'Internal Link'
                  elsif link.action[:S] == :URI
                    link.action[:URI]
                  else
                    'Internal Link'
                  end
            
            link_data = {
              page: page_num + 1,
              type: 'annotation',
              rect: link[:Rect],
              uri: uri
            }
            all_links << link_data
          rescue => e
            log_message("Error processing annotation link: #{e.message}", :error)
          end
        end
      rescue => e
        log_message("Error processing annotations on page #{page_num + 1}: #{e.message}", :error)
      end

      # Method 2: Extract text and look for URL patterns
      begin
        # Use process_contents to extract text
        text = ''
        processor = HexaPDF::Content::Processor.new do |*args|
          if args.first == :show_text
            text << args.last[:string]
          end
        end
        
        page.process_contents(processor)
        
        log_message("Extracted #{text.length} characters of text from page #{page_num + 1}")
        
        # Look for URLs and email addresses
        urls = text.scan(/(?:https?:\/\/|www\.)[^\s<>"']+|[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/)
        
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
          log_message("Found text link: #{link_data[:uri]}")
        end
      rescue => e
        log_message("Error extracting text from page #{page_num + 1}: #{e.message}", :error)
        log_message("Error details: #{e.backtrace.first(5).join("\n")}", :error)
      end
    end

    log_message("Total links found: #{all_links.length}")
    
    if all_links.empty?
      log_message("No links found in the document. This might mean either:", :warn)
      log_message("1. The PDF doesn't contain any links", :warn)
      log_message("2. The links are images or non-selectable text", :warn)
      log_message("3. The text extraction didn't work properly", :warn)
    end
    
    all_links
  rescue => e
    log_message("PDF extraction error: #{e.full_message}", :error)
    raise "Error processing PDF: #{e.message}"
  end
end
