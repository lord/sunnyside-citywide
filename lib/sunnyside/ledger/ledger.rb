require 'prawn'
module Sunnyside
  # This should be redone.
  def self.ledger_file
    Dir["#{LOCAL_FILES}summary/*.PDF"].each {|file| 
      if Filelib.where(filename: file).count == 0 
        puts "processing #{file}..."
        ledger = Ledger.new(file)
        ledger.process_file
        Filelib.insert(filename: file)
      end
    }
  end
  
  class Ledger
    attr_reader   :post_date, :file, :pages

    # when Ledger gets initialized, the page variable filters out the VNS clients
    # and then proceeds to pass the page date onto the PageData class

    def initialize(file)
      @file      = file
      @pages     = PDF::Reader.new(file).pages.select { |page| !page.raw_content.include?('VISITING NURSE SERVICE') }
    end

    def providers
      pages.map { |page| PageData.new(page.raw_content, file) }
    end

    def process_file
      providers.each { |page| page.invoice_data }
    end
  end

  # in PageData, the providers name is captured from the PDF::Reader raw_content, and the post date from the file name.
  # the rest of the data (the invoices) gets split by newlines (filted by those lines that fit the criteria for invoice data)
  # Then, the data gets finalized (via the InvoiceLine child class of PageData) and inserted into the database. 

  class PageData
    attr_reader :page_data, :provider, :post_date

    def initialize(page_data, file, provider = nil)
      @provider  = page_data[/CUSTOMER:\s+(.+)(?=\)')/, 1]
      @post_date = Date.parse(file[8..15])
      @page_data = page_data.split(/\n/).select { |line| line =~ /^\([0-9\/]+\s/ }
    end

    # Since the source data is somewhat unreliable in the format, there have been two different variations of AMERIGROUP and ELDERSERVE.
    # This method accounts for the aberrations while still maintaining that any provider not recognized by the DB to be saved as a PRIVATE client.

    def formatted_provider
      case provider
      when 'ELDERSERVEHEALTH' then 'ELDERSERVE HEALTH'
      when 'AMERIGROUP'       then 'AMERIGROUP 2'
      else 
        'PRIVATE'        
      end
    end

    def invoice_lines
      page_data.map { |line| InvoiceLine.new(line, formatted_provider, post_date) }
    end

    def invoice_data
      invoice_lines.each { |inv| inv.finalize }
    end

    # InvoiceLine does all the nitty-gritty parsing of an invoice line into the necessary fields the DB requres.

    class InvoiceLine < PageData
      attr_accessor :invoice, :rate, :hours, :amount, :client_id, :client_name, :post_date, :provider_id, :provider
      def initialize(line, provider, post_date)
        @provider                                               = provider
        @post_date                                              = post_date
        @provider_id                                            = Provider.where(name: provider).get(:id)
        @client_name                                            = line.slice!(20..45)
        @doc_date, @invoice, @client_id, @hours, @rate, @amount = line.split
      end

      # Some invoice totals exceed $999.99, so the strings need to be parsed into a format, sans comma, that the DB will read correctly. 
      # Otherwise, the DB will read 1,203.93 as 1.0.

      def amt
        amount.gsub(/,/, '')
      end

      # Ocasionally, new clients will appear on the PDF doc. If the DB does not find a client with the client_id, then it executes a method wherein
      # new client gets saved into the DB with a new FUND EZ ID. It must do this before saving the invoice information.

      def finalize
        if !client_missing? 
          add_invoice
        else 
          add_client
          finalize
        end
      end

      def client_missing?
        Client[client_id].nil?
      end

      def add_client
        Client.insert(client_number: client_id, client_name: client_name)
      end

      # rarely there may be an invoice line that contains an invoice number that already exists. This method accounts for it, by merely updating the amount.
      # There has only been two instances of this happening and both occurred in 2011.

      def add_invoice
        if invoice_exist?
          update_invoice
        else
          Invoice.insert(invoice_number: invoice, rate: rate, hours: hours, amount: amt, client_id: client_id, post_date: post_date, provider_id: provider_id, client_name: client_name.strip)
        end
      end

      def invoice_exist?
        Invoice.where(invoice_number: invoice).count > 0
      end

      def update_invoice
        Invoice.where(invoice_number: invoice).update(amount: amt.to_f)
      end

      def prev_amt
        Invoice.where(invoice_number: invoice).get(:amount)
      end
    end
  end
end