module Braintree
  module AttributeClass
    def self.new(*attributes)
      klass = Class.new
      klass.send :attr_reader,
                 *attributes.map {|a| a.is_a?(Hash) ? a.keys : a}.flatten

      define_initializer klass, attributes
      klass
    end

    def self.define_initializer(klass, attributes)
      klass.class_eval %{
        def initialize(attrs)
          #{attributes.inject("") do |code, attr|
            if attr.is_a?(Hash)
              code + attr.inject("") do |code_p, (attr_name, attr_class)|
                code_p + "@#{attr_name} = #{attr_class}.new(attrs[:#{attr_name}]) if attrs[:#{attr_name}];"
              end
            else
              code + "@#{attr} = attrs[:#{attr}]; "
            end
          end}
        end
      }
    end
  end

  class CreditCard < AttributeClass.new(:number, :expiration_date,
                                        :cardholder_name, :cvv)
    def bin
      number[0..5] if number
    end

    def last_4
      number[-4,4] if number
    end

    def token
      "AAAA"
    end
  end

  Customer = AttributeClass.new(:first_name, :last_name, :company,
                                :phone, :fax, :website, :email)

  Address = AttributeClass.new(:first_name,
                               :street_address,
                               :extended_address,
                               :locality,
                               :region,
                               :postal_code)

  class Transaction < AttributeClass.new(:amount,
                                         :order_id,
                                         :merchant_account_id,
                                         :options,
                                         :credit_card => CreditCard,
                                         :customer => Customer,
                                         :billing => Address,
                                         :shipping => Address)

    attr_reader :status
    attr_reader :type

    def _status=(status)
      @status = status
    end

    def _type=(type)
      @type = type
    end

    def id
      object_id
    end

    def errors
      errors = Errors.new

      if amount.blank?
        errors.add_unless_blank "Amount is required"
      elsif amount !~ /\A\d+(\.\d\d)?\Z/
        errors.add_unless_blank "Amount is an invalid format"
      elsif amount.to_f < 0
        errors.add_unless_blank "Amount cannot be negative"
      elsif amount.to_f > 9_999_999.99
        errors.add_unless_blank "Amount is too large"
      end

      if order_id && order_id.length > 255
        errors.add_unless_blank "Order id is too long"
      end

      if billing.present? && credit_card.blank?
        errors.add_unless_blank "Cannot provide a billing address unless also providing a credit card"
      end

      if credit_card.blank?
        errors.add_unless_blank "Need a customer_id, payment_method_token, credit_card, or subscription_id."
      end

      errors
    end

    module Status
      ["SettlementFailed",
       "GatewayRejected",
       "Voided",
       "Settled",
       "Authorized",
       "Unknown",
       "ProcessorDeclined",
       "Authorizing",
       "SubmittedForSettlement",
       "Failed"].each do |const|
        const_set(const, const.underscore)
      end
    end

    def submit_for_settlement!
      if @status == Status::Authorized
        @status = Status::SubmittedForSettlement
      else
        raise "Transaction not authorized"
      end
    end

    def avs_error_response_code
      case billing.try(:postal_code).to_s
      when "30000"; "E" # (AVS system error)
      when "30001"; "S" # (issuing bank does not support AVS)
      else ""
      end
    end

    def avs_postal_code_response_code
      case billing.try(:postal_code).to_s
      when "20000"; "N" # (does not match)
      when "20001"; "U" # (not verified)
      when /\A\S*\Z/; "I" # (not provided)
      else "M" # matches
      end
    end

    def avs_street_address_response_code
      case billing.try(:street_address).to_s
      when /\A200/; "N" # (does not match)
      when /\A201/; "U" # (not verified)
      when /\A\S*\Z/; "I" # (not provided)
      else "M" #matches
      end
    end

    def cvv_response_code
      case credit_card.try(:cvv).to_s
      when "200"; "N" # (does not match)
      when "201"; "U" # (not verified)
      when "301"; "S" # (issuer does not participate)
      when /\A\S*\Z/; "I" # (not provided)
      else "M" #matches
      end
    end

    def processor_authorization_code
      "03589B"
    end

    def processor_response_code
      if FAKE_PROCESSOR_RESPONSES[amount.to_i.to_s]
        return amount.to_i.to_s
      end
      if (2047.00..2099.00).include?(amount.to_f)
        return "2046" # declined
      end

      return "1000" # approved
    end

    def processor_response_text
      FAKE_PROCESSOR_RESPONSES[processor_response_code]
    end

    def credit_card_details
      credit_card
    end

    def billing_details
      billing
    end

    def shipping_details
      shipping
    end

    def self.sale(attributes)
      t = Transaction.new(attributes)

      if t.errors.size == 0
        t._status =
          ("1000".."1002").include?(t.processor_response_code) ?
          Status::Authorized : Status::ProcessorDeclined
        t._type = "sale"

        if t.status == Status::Authorized
          SuccessResult.new :transaction => t
        else
          ErrorResult.new :errors => Errors.new, :transaction => t
        end
      else
        ErrorResult.new :errors => t.errors
      end
    end

    def self.new(*args)
      t = super
      _transactions[t.id.to_s] = t
      t
    end

    def self.find(id)
      _transactions[id.to_s]
    end

    def self._setup_transparent_redirect(request = nil, &block)
      vendor_string = Base64.encode64(block.object_id.to_s)
      _transparent_redirects[vendor_string] = block
      if request
        request.env["QUERY_STRING"] = vendor_string
        request.env.extend QueryStringConflictDetection
      end
      vendor_string
    end

    module QueryStringConflictDetection
      def []=(*args)
        if args.size == 2 && args.first == "QUERY_STRING"
          if args.second.present?
            raise "FakeBraintree setup query string #{self["QUERY_STRING"].inspect}, but it was about to get overwritten with #{args.second.inspect}"
          end
        else
          super(*args)
        end
      end

      class Error < StandardError; end
    end

    def self.create_from_transparent_redirect(vendor_string)
      _transparent_redirects[vendor_string.to_s].call
    end

    def self._transactions
      @_transactions ||= {}
    end

    def self._transparent_redirects
      @_transparent_redirects ||= {}
    end

    def self.create_transaction_url
      "http://braintree.example.com/transactions"
    end
  end

  class SuccessResult < AttributeClass.new(:transaction)
    attr_reader :errors
    def initialize(attributes)
      super
      @errors = Errors.new
    end

    def success?
      true
    end
  end

  class ErrorResult < AttributeClass.new(:errors, :transaction)
    def success?
      false
    end
  end

  Error = AttributeClass.new(:message)

  class Errors
    include Enumerable

    def initialize
      @errors = []
    end

    def add_unless_blank(message)
      @errors << Error.new(:message => message) unless message.blank?
    end

    def each
      @errors.each do |e|
        yield e
      end
    end

    def size
      @errors.length
    end
  end

  module TransparentRedirect
    def self.transaction_data(hash)
      hash.to_json
    end
  end

  FAKE_PROCESSOR_RESPONSES = {
    "1000" => "Approved",
    "1001" => "Approved, check customer ID",
    "1002" => "Processed (Successful Credit)",
    "2000" => "Do Not Honor",
    "2001" => "Insufficient Funds",
    "2002" => "Limit Exceeded",
    "2003" => "Cardholder's Activity Limit Exceeded",
    "2004" => "Expired Card",
    "2005" => "Invalid Credit Card Number",
    "2006" => "Invalid Date",
    "2007" => "No Account",
    "2008" => "Card Account Length Error",
    "2009" => "No Such Issuer",
    "2010" => "Card Issuer Declined CVV",
    "2011" => "Voice Authorization Required",
    "2012" => "Voice Authorization Required. Possible Lost Card",
    "2013" => "Voice Authorization Required. Possible stolen card",
    "2014" => "Voice Authorization Required. Fraud Suspected.",
    "2015" => "Transaction Not Allowed",
    "2016" => "Duplicate Transaction",
    "2017" => "Cardholder Stopped Billing",
    "2018" => "Cardholder Stopped All Billing",
    "2019" => "Declined by Issuer- Invalid Transaction",
    "2020" => "Violation",
    "2021" => "Security Violation",
    "2022" => "Declined- Updated cardholder available",
    "2023" => "Processor does not support this feature",
    "2024" => "Card Type not enabled",
    "2025" => "Set up error- Merchant",
    "2026" => "Invalid Merchant ID",
    "2027" => "Set up error - Amount",
    "2028" => "Set Up Error - Hierarchy",
    "2029" => "Set up error- Card",
    "2030" => "Set up error- Terminal",
    "2031" => "Encryption Error",
    "2032" => "Surcharge Not Permitted",
    "2033" => "Inconsistent Data",
    "2034" => "No Action Taken",
    "2035" => "Partial Approval for amount in Group III version",
    "2036" => "Unsolicited Reversal",
    "2037" => "Already Reversed",
    "2038" => "Processor Declined",
    "2039" => "Invalid Authorization Code",
    "2040" => "Invalid Store",
    "2041" => "Declined Call for Approval",
    "2043" => "Error. Do not retry, call issuer",
    "2044" => "Declined. Call issuer",
    "2045" => "Invalid Merchant Number",
    "2046" => "Declined",
    "2047" => "Call Issuer. Pick Up Card",
    "3000" => "Processor network unavailable.Try Again"
  }
end

