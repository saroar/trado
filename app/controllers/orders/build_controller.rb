class Orders::BuildController < ApplicationController
  include Wicked::Wizard

  skip_before_filter :authenticate_user!

  steps :review, :billing, :shipping, :payment, :confirm

  def show
    @cart = current_cart
    @order = Order.find(params[:order_id])
    if @order.transaction || current_cart.cart_items.empty?
      redirect_to root_url, flash[:notice] => "You do not have permission to amend this order."
    else
      case step
      when :billing
        # If billing address exists, load the current record and populate the fields
        if @order.bill_address_id
          @billing_address = Address.find(@order.bill_address_id)
        else
          # Else create a new record
          @billing_address = Address.new
        end
      end
      case step
      when :shipping
        if @order.ship_address_id
          @shipping_address = Address.find(@order.ship_address_id)
        else
          # Else create a new record
          @shipping_address = Address.new
        end
        @calculated_tier = @order.calculate_shipping_tier(current_cart)
      end
      case step 
      when :payment
        @order.calculate_order(current_cart, session)
      end
      case step
      when :confirm
        if defined?(params[:token])
          @order.assign_paypal_token(params[:token], params[:PayerID], session)
        end
      end
      render_wizard
    end
  end

  def update 
    @order = Order.find(params[:order_id])
    # Sets current state of the order
    if step == steps.last
      @order.update_column(:status, 'active')
    else
      @order.update_column(:status, step.to_s)
    end
    case step 
    when :billing
      if @order.bill_address_id
        @billing_address = Address.find(@order.bill_address_id)
      else
        @billing_address = Address.new(:addressable_id => @order.id, :addressable_type => 'Order')
      end
      # Update billing attributes
      if @billing_address.update_attributes(params[:address])
        # Add billing ID to order record
        @order.update_column(:bill_address_id, @billing_address.id) unless @order.bill_address_id
        # Update order attributes in the form
        unless @order.update_attributes(params[:order])
          # if unsuccessful re-render the form with order errors
          render_wizard @order
        else
          # else continue to the next stage
          render_wizard @billing_address
        end
      end  
    end
    case step
    when :shipping
      @calculated_tier = @order.calculate_shipping_tier(current_cart)
      if @order.ship_address_id
        @shipping_address = Address.find(@order.ship_address_id)
      else
        @shipping_address = Address.new(:addressable_id => @order.id, :addressable_type => 'Order')
      end
      # Update billing attributes
      if @shipping_address.update_attributes(params[:address])
        # Add billing ID to order record
        @order.update_column(:ship_address_id, @shipping_address.id) unless @order.ship_address_id
        # Update order attributes in the form
        unless @order.update_attributes(params[:order])
          # if unsuccessful re-render the form with order errors
          render_wizard @order
        else
          # else continue to the next stage
          render_wizard @shipping_address
        end
      end
    end
  end

  def express
    @order = Order.find(params[:order_id])
    if @order.transaction || current_cart.cart_items.empty?
      redirect_to root_url, flash[:notice] => "You do not have permission to amend this order."
    else
      response = EXPRESS_GATEWAY.setup_purchase(price_in_pennies(session[:total]), express_setup_options(@order))
      redirect_to EXPRESS_GATEWAY.redirect_url_for(response.token)
    end
  end

  def purchase 
    @order = Order.find(params[:order_id])
    if @order.transaction || current_cart.cart_items.empty?
      redirect_to root_url, flash[:notice] => "You do not have permission to amend this order."
    else
      response = EXPRESS_GATEWAY.purchase(price_in_pennies(session[:total]), express_purchase_options(@order))
      if response.params['payment_status'] == 'Completed'
        @order.add_cart_items_from_cart(current_cart)
        Cart.destroy(session[:cart_id])
        session[:cart_id] = nil
        @order.successful_order(response)
        Notifier.order_received(@order).deliver
        redirect_to success_order_build_url(:order_id => @order.id, :id => steps.last, :transaction_id => response.params['PaymentInfo']['TransactionID'])
      else
        @order.failed_order(response)
        redirect_to failure_order_build_url(:order_id => @order.id, :id => steps.last, :response => response.message, :error_code => response.params["error_codes"], :correlation_id => response.params['correlation_id'])
      end
    end
  end

  def success
    @order = Order.find(params[:order_id])

    respond_to do |format|
      unless params[:transaction_id].blank?
        format.html
      else
        format.html { redirect_to root_url }
      end
    end
  end

  def failure
    @order = Order.find(params[:order_id])

    respond_to do |format|
      unless params[:correlation_id].blank?
        format.html
      else
        format.html { redirect_to root_url }
      end
    end
  end

  def purge
    @order = Order.find(params[:order_id])
    unless @order.transaction
      @order.destroy
      redirect_to root_url, notice: 'Your order has been deleted.'
    else
      redirect_to root_url, flash[:notice] => 'Cannot delete a completed order.'
    end
  end

private

  def express_purchase_options(order)
    {
      :subtotal          => price_in_pennies(session[:sub_total]),
      :shipping          => price_in_pennies(order.shipping_cost),
      :tax               => price_in_pennies(session[:tax]),
      :handling          => 0,
      :token             => order.express_token,
      :payer_id          => order.express_payer_id,
      :currency          => 'GBP'
    }
  end

  def express_setup_options(order)
    {
      :subtotal          => price_in_pennies(session[:sub_total]),
      :shipping          => price_in_pennies(order.shipping_cost),
      :tax               => price_in_pennies(session[:tax]),
      :handling          => 0,
      :order_id          => order.id,
      :items             => express_items,
      :ip                => request.remote_ip,
      :return_url        => order_build_url(:order_id => order.id, :id => steps.last),
      :cancel_return_url => order_build_url(:order_id => order.id, :id => 'payment'),
      :currency          => 'GBP',
    }
  end

  def price_in_pennies(price)
    (price*100).round
  end

  def express_items
    current_cart.cart_items.collect do |item|
      {
        :name => item.sku.product.name,
        :description => "#{item.sku.attribute_value}#{item.sku.attribute_type.measurement unless item.sku.attribute_type.measurement.nil? }",
        :amount => price_in_pennies(item.price), 
        :quantity => item.quantity 
      }
    end
  end

end