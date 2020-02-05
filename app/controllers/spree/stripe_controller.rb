# frozen_string_literal: true

module Spree
  class StripeController < Spree::BaseController
    include Core::ControllerHelpers::Order

    def confirm_payment
      begin
        if params[:stripe_payment_method_id].present?
          intent = stripe.create_intent(
            (current_order.total * 100).to_i,
            params[:stripe_payment_method_id],
            currency: current_order.currency,
            confirmation_method: 'manual',
            confirm: true,
            setup_future_usage: 'on_session',
            metadata: { order_id: current_order.id }
          )
        elsif params[:stripe_payment_intent_id].present?
          intent = stripe.confirm_intent(params[:stripe_payment_intent_id], nil)
        end
      rescue Stripe::CardError => e
        render json: { error: e.message }
        return
      end

      generate_payment_response(intent)
    end

    def shipping_rates
      # setting a temporary and probably incomplete address to the order
      # only to calculate the available shipping rate options:
      current_order.ship_address = address_from_params

      if shipping_options.any?
        render json: { success: true, shipping_options: shipping_options }
      else
        render json: { success: false, error: 'No shipping method available for that address' }
      end
    end

    def shipping_address
      current_order.restart_checkout_flow

      address = address_from_params

      if address.valid?
        current_order.ship_address = address
        current_order.bill_address ||= address

        while !current_order.payment?
          current_order.next || break
        end

        if current_order.payment?
          render json: { success: true }
        else
          render json: { success: false, error: 'Order not ready for payment. Try manual checkout.' }
        end
      else
        render json: { success: false, error: address.errors.full_messages.to_sentence }
      end
    end

    private

    def address_from_params
      # attributes that should be always present:
      country = Spree::Country.find_by_iso(params[:shipping_address][:country])
      city = params[:shipping_address][:city]
      zipcode = params[:shipping_address][:postalCode]
      state = country.states.find_by_abbr(params[:shipping_address][:region])
      # possibly anonymized attributes:
      phone = params[:shipping_address][:phone]
      lines = params[:shipping_address][:addressLine]
      names = params[:shipping_address][:recipient].split(' ')

      attributes = {
        country_id: country.id,
        city: city,
        zipcode: zipcode
      }

      attributes.merge!(state_id: state.id) if state
      attributes.merge!(firstname: names.first) if names.first
      attributes.merge!(lastname: names.last) if names.last
      attributes.merge!(phone: phone) if phone
      attributes.merge!(address1: lines.first) if lines.first
      attributes.merge!(address2: lines.second) if lines.second

      spree_current_user.addresses.find_or_initialize_by(attributes)
    end

    def shipping_options
      @shipping_options ||= begin
        shipments = Spree::Stock::SimpleCoordinator.new(current_order).shipments
        all_rates = shipments.map(&:shipping_rates).flatten
        available_methods = all_rates.group_by(&:shipping_method_id).select do |_, rates|
          rates.size == shipments.size
        end

        available_methods.each_with_object([]) do |available_method, options|
          id, rates = available_method

          options << {
            id: id.to_s,
            label: Spree::ShippingMethod.find(id).name,
            amount: (rates.sum(&:cost) * 100).to_i
          }
        end
      end
    end

    def stripe
      @stripe ||= Spree::PaymentMethod::StripeCreditCard.find(params[:spree_payment_method_id])
    end

    def generate_payment_response(intent)
      response = intent.params
      # Note that if your API version is before 2019-02-11, 'requires_action'
      # appears as 'requires_source_action'.
      if %w[requires_source_action requires_action].include?(response['status']) && response['next_action']['type'] == 'use_stripe_sdk'
          render json: {
            requires_action: true,
            stripe_payment_intent_client_secret: response['client_secret']
          }
      elsif response['status'] == 'succeeded'
        render json: { success: true }
      else
        render json: { error: response['error']['message'] }, status: 500
      end
    end
  end
end
