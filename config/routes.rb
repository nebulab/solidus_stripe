Spree::Core::Engine.routes.draw do
  post '/stripe/confirm_payment', to: 'stripe#confirm_payment'
  post '/stripe/shipping_rates', to: 'stripe#shipping_rates'
  post '/stripe/shipping_address', to: 'stripe#shipping_address'
end
