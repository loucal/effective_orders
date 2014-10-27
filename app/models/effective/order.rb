module Effective
  class Order < ActiveRecord::Base
    self.table_name = EffectiveOrders.orders_table_name.to_s

    acts_as_obfuscated

    acts_as_addressable :billing => EffectiveOrders.require_billing_address, :shipping => EffectiveOrders.require_shipping_address
    attr_accessor :save_billing_address, :save_shipping_address, :shipping_address_same_as_billing # save these addresses to the user if selected

    belongs_to :user  # This is the user who purchased the order
    has_many :order_items, :inverse_of => :order

    structure do
      payment         :text   # serialized hash, see below
      purchase_state  :string, :validates => [:inclusion => {:in => [nil, EffectiveOrders::PURCHASED, EffectiveOrders::DECLINED]}]
      purchased_at    :datetime, :validates => [:presence => {:if => Proc.new { |order| order.purchase_state == EffectiveOrders::PURCHASED}}]

      timestamps
    end

    accepts_nested_attributes_for :order_items, :allow_destroy => false, :reject_if => :all_blank
    accepts_nested_attributes_for :user, :allow_destroy => false, :update_only => true

    unless EffectiveOrders.skip_user_validation
      validates_presence_of :user_id
      validates_associated :user
    end

    if ((minimum_charge = EffectiveOrders.minimum_charge.to_f) rescue nil).present?
      if EffectiveOrders.allow_free_orders
        validates_numericality_of :total, :greater_than_or_equal_to => minimum_charge, :unless => Proc.new { |order| order.total < 0.01 && order.total >= 0.00 }, :message => "A minimum order of #{EffectiveOrders.minimum_charge} is required.  Please add additional items to your cart."
      else
        validates_numericality_of :total, :greater_than_or_equal_to => minimum_charge, :message => "A minimum order of #{EffectiveOrders.minimum_charge} is required.  Please add additional items to your cart."
      end
    end

    validates_presence_of :order_items, :message => 'No items are present.  Please add one or more item to your cart.'
    validates_associated :order_items

    serialize :payment, Hash

    default_scope -> { includes(:user).includes(:order_items => :purchasable).order('created_at DESC') }

    scope :purchased, -> { where(:purchase_state => EffectiveOrders::PURCHASED) }
    scope :purchased_by, lambda { |user| purchased.where(:user_id => user.try(:id)) }
    scope :declined, -> { where(:purchase_state => EffectiveOrders::DECLINED) }

    def initialize(cart = {}, user = nil)
      super() # Call super with no arguments

      # Set up defaults
      self.save_billing_address = true
      self.save_shipping_address = true
      self.shipping_address_same_as_billing = true

      if cart.kind_of?(Effective::Cart)
        cart_items = cart.cart_items
      elsif cart.present? == false
        cart_items = []
      else
        purchasables = [cart].flatten

        if purchasables.all? { |purchasable| purchasable.respond_to?(:is_effectively_purchasable?) }
          cart_items = purchasables.map do |purchasable|
            CartItem.new(:quantity => 1).tap { |cart_item| cart_item.purchasable = purchasable }
          end
        else
          throw ArgumentError.new("Order.new() expects an Effective::Cart, a single acts_as_purchasable item, or an array of acts_as_purchasable items")
        end
      end

      cart_items.each do |item|
        self.order_items.build(
          :title => item.title,
          :quantity => item.quantity,
          :price => item.price,
          :tax_exempt => item.tax_exempt,
          :tax_rate => item.tax_rate,
          :quickbooks_item_name => item.quickbooks_item_name,
          :purchasable_id => item.purchasable_id,
          :purchasable_type => item.purchasable_type,
          :seller_id => (item.purchasable.try(:seller).try(:id) rescue nil)
        )
      end

      self.user = user if user.present?
    end

    def user=(user)
      super

      self.billing_address = user.billing_address if user.respond_to?(:billing_address)
      self.shipping_address = user.shipping_address if user.respond_to?(:shipping_address)
    end

    # This is used for updating Subscription codes.
    # We want to update the underlying purchasable object of an OrderItem
    # Passing the order_item_attributes using rails default acts_as_nested creates a new object instead of updating the temporary one.
    # So we override this method to do the updates on the non-persisted OrderItem objects
    # Right now strong_paramaters only lets through stripe_coupon_id
    # {"0"=>{"class"=>"Effective::Subscription", "stripe_coupon_id"=>"50OFF", "id"=>"2"}}}
    def order_items_attributes=(order_item_attributes)
      if self.persisted? == false
        (order_item_attributes || {}).each do |_, atts|
          order_item = self.order_items.find { |oi| oi.purchasable.class.name == atts[:class] && oi.purchasable.id == atts[:id].to_i }

          if order_item
            order_item.purchasable.attributes = atts.except(:id, :class)

            # Recalculate the OrderItem based on the updated purchasable object
            order_item.title = order_item.purchasable.title
            order_item.price = order_item.purchasable.price
            order_item.tax_exempt = order_item.purchasable.tax_exempt
            order_item.tax_rate = order_item.purchasable.tax_rate
            order_item.seller_id = (order_item.purchasable.try(:seller).try(:id) rescue nil)
          end
        end
      end
    end

    def total
      [order_items.collect(&:total).sum, 0.00].max
    end

    def subtotal
      order_items.collect(&:subtotal).sum
    end

    def tax
      [order_items.collect(&:tax).sum, 0.00].max
    end

    def num_items
      order_items.to_a.sum(&:quantity)
    end

    def save_billing_address?
      ::ActiveRecord::ConnectionAdapters::Column::TRUE_VALUES.include?(self.save_billing_address)
    end

    def save_shipping_address?
      ::ActiveRecord::ConnectionAdapters::Column::TRUE_VALUES.include?(self.save_shipping_address)
    end

    def shipping_address_same_as_billing?
      if self.shipping_address_same_as_billing.nil?
        true # Default value
      else
        ::ActiveRecord::ConnectionAdapters::Column::TRUE_VALUES.include?(self.shipping_address_same_as_billing)
      end
    end

    def purchase!(payment_details = nil)
      raise EffectiveOrders::AlreadyPurchasedException.new('order already purchased') if self.purchased?
      raise EffectiveOrders::AlreadyDeclinedException.new('order already declined') if self.declined?

      Order.transaction do
        self.purchase_state = EffectiveOrders::PURCHASED
        self.purchased_at = Time.zone.now
        self.payment = payment_details.kind_of?(Hash) ? payment_details : {:details => (payment_details || 'none').to_s}

        order_items.each { |item| item.purchasable.purchased!(self, item) }

        self.save!

        if EffectiveOrders.mailer[:send_order_receipt_to_admin]
          if Rails.env.production?
            (OrdersMailer.order_receipt_to_admin(self).deliver rescue false)
          else
            OrdersMailer.order_receipt_to_admin(self).deliver
          end
        end

        if EffectiveOrders.mailer[:send_order_receipt_to_buyer]
          if Rails.env.production?
            (OrdersMailer.order_receipt_to_buyer(self).deliver rescue false)
          else
            OrdersMailer.order_receipt_to_buyer(self).deliver
          end
        end

        if EffectiveOrders.mailer[:send_order_receipt_to_seller] && self.purchased?(:stripe_connect)
          self.order_items.group_by(&:seller).each do |seller, order_items|
            if Rails.env.production?
              (OrdersMailer.order_receipt_to_seller(self, seller, order_items).deliver rescue false)
            else
              OrdersMailer.order_receipt_to_seller(self, seller, order_items).deliver
            end
          end
        end

        return true
      end

      false
    end

    def decline!(payment_details = nil)
      raise EffectiveOrders::AlreadyPurchasedException.new('order already purchased') if self.purchased?
      raise EffectiveOrders::AlreadyDeclinedException.new('order already declined') if self.declined?

      Order.transaction do
        self.purchase_state = EffectiveOrders::DECLINED
        self.payment = payment_details.kind_of?(Hash) ? payment_details : {:details => (payment_details || 'none').to_s}

        order_items.each { |item| item.purchasable.declined!(self, item) }

        self.save!
      end
    end

    def purchased?(provider = nil)
      return false if (purchase_state != EffectiveOrders::PURCHASED)
      return true if provider == nil

      begin
        case provider
        when :stripe_connect
          payment.keys.first.kind_of?(Numeric) && payment[payment.keys.first].key?('object') && payment[payment.keys.first]['object'] == 'charge'
        when :stripe
          payment.key?('object') && payment['object'] == 'charge'
        when :moneris
          payment.key?('response_code') && payment.key?('transactionKey')
        when :paypal
        else
          false
        end
      rescue => e
        false
      end
    end

    def declined?
      purchase_state == EffectiveOrders::DECLINED
    end
  end
end
