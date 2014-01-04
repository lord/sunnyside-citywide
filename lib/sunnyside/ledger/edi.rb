module Sunnyside
  def self.edi_parser
    print "checking for new files...\n"
    Dir["#{DRIVE}/sunnyside-files/835/*.txt"].select { |file| Filelib.where(:filename => file).count == 0 }.each do |file|
      print "processing #{file}...\n"
      data = File.open(file).read

      # Detect to see if the EDI file already has new lines inserted. If so, the newlines are removed before the file gets processed.

      data.gsub!(/\n/, '')

      data  = data.split(/~CLP\*/)
      edi   = Edi.new(data, file)
      edi.parse_claim_header
      Filelib.insert(filename: file, created_at: Time.now, purpose: 'EDI Import', file_type: '835 Remittance')
      edi.save_payment_to_db
      FileUtils.mv(file, "#{DRIVE}/sunnyside-files/835/archive/#{File.basename(file)}")
    end
  end

  class Edi
    attr_reader :header, :claims, :file
    def initialize(data, file)
      @header, @claims = data[0], data.drop(1)
      @file            = file
    end

    def process_file
      claims.map { |clm| clm.split(/~(?=SVC)/) }.each do |claim|
        claim_head = claim[0]
        services   = claim.select { |section| section =~ /^SVC/ }
        InvoiceHeader.new(claim_head, services).parse_data
      end
    end

    def check_number
      header[/(?<=~TRN\*\d\*)\w+/, 0]
    end

    def check_total
      header[/(?<=~BPR\*\w\*)[0-9\.\-]+/] || 0.0
    end

    def type
      if header[/(?<=\*C\*)ACH/] == 'ACH'
        'Electronic Funds Transfer'
      elsif header[/(?<=\*C\*)CHK/] == 'CHK'
        'Physical Check Issued'
      else
        'Non Payment'
      end
    end

    # not working

    # def check
    #   if check_number.include?('E') # E for Fidelis
    #     check_number[/\d+[A-Z]+(\d+)/, 1] 
    #   else
    #     check_number
    #   end
    # end

    def separate_claims_from_services
      claims.map {|clm| clm.split(/~(?=SVC)/)}
    end

    def parse_claim_header
      separate_claims_from_services.each do |clm|
        claim_data = clm[0]
        services   = clm.reject{|x| x !~ /^SVC/}
        claims     = InvoiceHeader.new(claim_data, check_number)
        claims.format_data
        claims.add_to_db(check_number, file)
        parse_service(services) {|svc| claims.parse_svc(svc, check_number)}
      end
    end

    def save_payment_to_db
      provider = Claim.where(check_number: check_number).get(:provider_id) || 17
      Payment.insert(provider_id: provider, filelib_id: filelib_id, check_total: check_total, check_number: check_number)
    end

    def filelib_id
      Filelib.where(filename: file).get(:id)
    end

    def parse_service(services)
      services.map{|x| x.split(/~/).reject{|x| x !~ /CAS|SVC|DTM/}}.each {|svc| yield svc}
    end
  end

  class InvoiceHeader < Edi
    attr_accessor :claim_number, :invoice_number, :response_code, :amt_charged, :amt_paid, :check_number
    def initialize(claim, check_number)
      @invoice_number, @response_code, @amt_charged, @amt_paid, @whatever, @claim_number = claim.match(/^([\w\.]+)\*(\d+)\*([0-9\.\-]+)\*([0-9\.\-]+)\*([0-9\.\-]+)?\*+\w+\*(\w+)/).captures
      @check_number   = check_number
    end

    def format_data
      @invoice_number         = invoice_number[/^\w+/].gsub(/[OLD]/, 'O' => '0', 'D' => '8', 'L' => '1').gsub(/^0/, '')[0..5].to_i
    end

    def claim_id
      Claim.where(invoice_id: invoice_number, check_number: check_number).get(:id)
    end

    def parse_svc(service, check_number)
      if service.length == 2
        svc = Detail.new(service[0], service[1])
      elsif service.length > 2
        svc = Detail.new(service[0], service[1])
        svc.set_denial(service[2])
      end
      svc.display(invoice_number)
      svc.save_to_db(invoice_number, check_number, claim_id)
    end

    def prov
      Invoice.where(invoice_number: invoice_number).get(:provider_id)
    end

    def add_to_db(check, file)
      Claim.insert(provider_id: prov, invoice_id: invoice_number, billed: amt_charged, paid: amt_paid, check_number: check_number, control_number: claim_number, status: response_code)
    end
  end

  class Detail < Edi

    attr_reader :billed, :paid, :denial_reason, :date, :billed, :paid, :units, :service_code
    def initialize(service, date, denial_reason=nil, denial_code=nil)
      @service_code, @billed, @paid, @units = service.match(/HC:([A-Z0-9\:]+)\*([0-9\.\-]+)\*([0-9\.\-]+)?\**([0-9\-]+)?/).captures
      @date = Date.parse(date[/\d+$/])
    end

    def display(inv)
      print "#{inv} #{@service_code} #{@date} #{client(inv)} #{denial}\n"
    end

    def client(inv)
      Invoice.where(invoice_number: inv).get(:client_name)
    end

    def denial
      (billed.to_f - paid.to_f).round(2) if billed > paid
    end

    def set_denial(denial)
      @denial_reason = set_code(denial[/\d+/])
    end

    def save_to_db(invoice, check, claim_id)
      Service.insert(invoice_id: invoice, service_code: service_code, units: units.to_f, billed: billed.to_f, paid: paid.to_f, denial_reason: denial_reason, dos: date, claim_id: claim_id)
    end

    def set_code(code)
      case code
      when '125' 
        'Submission/billing error(s). At least one Remark Code must be provided'
      when '140' 
        'Patient/Insured health identification number and name do not match.'
      when '31'  
        'INVALID MEMBER ID'
      when '62'  
        'PAID AUTHORIZED UNITS'
      when '96'  
        'NO AUTHORIZATION FOR DOS'
      when '146' 
        'DIAGNOSIS WAS INVALID FOR DATES LISTED'
      when '197' 
        'Precertification/authorization/notification absent'
      when '198' 
        'Precertification/authorization exceeded'
      when '199' 
        'Revenue code and Procedure code do not match'
      when '9'   
        'DIAGNOSIS ISSUE'
      when '15'  
        'AUTHORIZATION MISSING/INVALID'
      when '18'  
        'Exact Duplicate Claim/Service'
      when '19'  
        'Expenses incurred prior to coverage'
      when '27'  
        'Expenses incurred after coverage terminated'
      when '29'  
        'Timely Filing'
      when '39'  
        'Services denied at the time authorization/pre-certification was requested'
      when '45'  
        'Charge exceeds fee schedule/maximum allowable'
      when '16'  
        'Claim/service lacks information which is needed for adjudication'
      when '50'  
        'These are non-covered services because this is not deemed a medical necessity by the payer'
      when '192' 
        'Non standard adjustment code from paper remittance'
      when '181' 
        'Procedure code was invalid on the date of service'
      when '182' 
        'Procedure modifier was invalid on the date of service'
      when '204' 
        'This service/equipment/drug is not covered under the patients current benefit plan'
      when '151' 
        '151 Payment adjusted because the payer deems the information submitted does not support this many/frequency of services'
      when '177' 
        'Patient has not met the required eligibility requirements'
      when '109' 
        'Claim/service not covered by this payer/contractor. You must send the claim/service to the correct payer/contractor.'
      else
        "#{code} is UNIDENTIFIED"
      end
    end
  end
end