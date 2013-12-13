module ActsAsPurchasable
  extend ActiveSupport::Concern

  module ActiveRecord
    def acts_as_purchasable(*options)
      @acts_as_purchasable = options || []
      include ::ActsAsPurchasable
    end
  end

  included do
    include ActiveSupport::Callbacks
    define_callbacks :purchased
    define_callbacks :declined

    has_many :orders, :through => :order_items
    has_many :order_items, :as => :purchasable
    has_many :cart_items, :as => :purchasable, :dependent => :delete_all

    validates_with Effective::SoldOutValidator, :on => :create

    validates :price, :presence => true, :numericality => true
    validates :tax_exempt, :inclusion => {:in => [true, false]}

    # These are breaking on the check for quanitty_enabled?.  More research is due
    validates :quantity_purchased, :numericality => {:allow_nil => true}, :if => proc { |purchasable| (purchasable.quantity_enabled? rescue false) }
    validates :quantity_max, :numericality => {:allow_nil => true}, :if => proc { |purchasable| (purchasable.quantity_enabled? rescue false) }
  end

  module ClassMethods
  end

  # Regular instance methods
  def price
    self[:price] || 0.00
  end

  def title
    self[:title] || 'ActsAsPurchasable'
  end

  def tax_exempt
    self[:tax_exempt] || false
  end

  def quickbooks_item_name
    self[:quickbooks_item_name] || ''
  end

  def seller
    raise ArgumentException('acts_as_purchasable object requires the seller be defined to return the User selling this item.  This is only used for StripeConnect.')
  end

  def purchased?
    #self.purchase_state == ActsAsPurchasable::PURCHASED
  end

  def declined?
    #self.purchase_state == ActsAsPurchasable::DECLINED
  end

  def quantity_enabled?
    self.respond_to?(:quantity_enabled) ? quantity_enabled == true : false
  end

  def quantity_remaining
    (quantity_max - quantity_purchased) rescue 0
  end

  def sold_out?
    quantity_enabled? ? (quantity_remaining == 0) : false
  end

  def purchased(order = nil)
    # self.purchase_state = ActsAsPurchasable::PURCHASED if respond_to?('purchase_state')
    # begin
    #   self.quantity_purchased = (self.quantity_purchased + 1)
    # rescue
    # end

    run_callbacks :purchased do
      @order = order
    end

    self.save
  end

  def declined(order = nil)
    # self.purchase_state = ActsAsPurchasable::DECLINED if respond_to?('purchase_state')

    run_callbacks :declined do
      @order = order
    end

    self.save
  end

  def is_effectively_purchasable?
    true
  end

end

