module Effective
  class Order < ActiveRecord::Base
    self.table_name = EffectiveOrders.orders_table_name.to_s

    if EffectiveOrders.obfuscate_order_ids
      acts_as_obfuscated :format => '###-####-###'
    end

    acts_as_addressable :billing => {:presence => EffectiveOrders.require_billing_address, :use_full_name => true}, :shipping => {:presence => EffectiveOrders.require_shipping_address, :use_full_name => true}
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

    if ((minimum_charge = EffectiveOrders.minimum_charge.to_i) rescue nil).present?
      if EffectiveOrders.allow_free_orders
        validates_numericality_of :total, :greater_than_or_equal_to => minimum_charge, :unless => Proc.new { |order| order.total == 0 }, :message => "A minimum order of #{EffectiveOrders.minimum_charge} is required.  Please add additional items to your cart."
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

      add_to_order(cart) if cart.present?

      self.user = user if user.present?
    end

    def add(item, quantity = 1)
      raise 'unable to alter a purchased order' if purchased?
      raise 'unable to alter a declined order' if declined?

      if item.kind_of?(Effective::Cart)
        cart_items = item.cart_items
      else
        purchasables = [item].flatten

        if purchasables.any? { |p| !p.respond_to?(:is_effectively_purchasable?) }
          raise ArgumentError.new('Effective::Order.add() expects a single acts_as_purchasable item, or an array of acts_as_purchasable items')
        end

        cart_items = purchasables.map do |purchasable|
          CartItem.new(:quantity => quantity).tap { |cart_item| cart_item.purchasable = purchasable }
        end
      end

      retval = cart_items.map do |item|
        order_items.build(
          :title => item.title,
          :quantity => item.quantity,
          :price => item.price,
          :tax_exempt => item.tax_exempt,
          :tax_rate => item.tax_rate,
          :seller_id => (item.purchasable.try(:seller).try(:id) rescue nil)
        ).tap { |order_item| order_item.purchasable = item.purchasable }
      end

      retval.size == 1 ? retval.first : retval
    end
    alias_method :add_to_order, :add

    def user=(user)
      super

      if user.respond_to?(:billing_address) && EffectiveOrders.require_billing_address
        self.billing_address = user.billing_address
        self.billing_address.full_name = billing_name if self.billing_address.present? && self.billing_address.full_name.blank?
      end

      if user.respond_to?(:shipping_address) && EffectiveOrders.require_shipping_address
        self.shipping_address = user.shipping_address
        self.shipping_address.full_name = billing_name if self.shipping_address.present? && self.shipping_address.full_name.blank?
      end
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
      [order_items.map(&:total).sum, 0].max
    end

    def subtotal
      order_items.map(&:subtotal).sum
    end

    def tax
      [order_items.map(&:tax).sum, 0].max
    end

    def num_items
      order_items.map(&:quantity).sum
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

    def billing_name
      if billing_address.try(:full_name).present?
        billing_address.full_name
      elsif user.respond_to?(:full_name)
        user.full_name.to_s
      elsif user.respond_to?(:first_name) && user.respond_to?(:last_name)
        user.first_name.to_s + ' ' + user.last_name.to_s
      elsif user.to_s.start_with?('#<User:') == false
        user.to_s
      else
        ''
      end
    end

    # :validate => false, :email => false
    def purchase!(payment_details = nil, opts = {})
      opts = {:validate => true, :email => true}.merge(opts)

      raise EffectiveOrders::AlreadyPurchasedException.new('order already purchased') if self.purchased?
      raise EffectiveOrders::AlreadyDeclinedException.new('order already declined') if (self.declined? && opts[:validate])

      Order.transaction do
        self.purchase_state = EffectiveOrders::PURCHASED
        self.purchased_at ||= Time.zone.now
        self.payment = payment_details.kind_of?(Hash) ? payment_details : {:details => (payment_details || 'none').to_s}

        order_items.each { |item| item.purchasable.purchased!(self, item) }

        self.save!(:validate => opts[:validate])

        if EffectiveOrders.mailer[:send_order_receipt_to_admin] && opts[:email]
          if Rails.env.production?
            (OrdersMailer.order_receipt_to_admin(self).deliver rescue false)
          else
            OrdersMailer.order_receipt_to_admin(self).deliver
          end
        end

        if EffectiveOrders.mailer[:send_order_receipt_to_buyer] && opts[:email]
          if Rails.env.production?
            (OrdersMailer.order_receipt_to_buyer(self).deliver rescue false)
          else
            OrdersMailer.order_receipt_to_buyer(self).deliver
          end
        end

        if EffectiveOrders.mailer[:send_order_receipt_to_seller] && self.purchased?(:stripe_connect) && opts[:email]
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
