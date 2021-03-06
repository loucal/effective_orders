if defined?(EffectiveDatatables)
  module Effective
    module Datatables
      class Orders < Effective::Datatable
        default_order :purchased_at, :desc

        table_column(:purchased_at) { |order| order.purchased_at.try(:strftime, '%Y-%m-%d %H:%M') }
        table_column :id

        table_column :email, column: 'users.email', label: 'Buyer Email', if: proc { attributes[:user_id].blank? } do |order|
          link_to order[:email], (edit_admin_user_path(order.user_id) rescue admin_user_path(order.user_id) rescue '#')
        end

        if EffectiveOrders.require_billing_address
          table_column :buyer_name, sortable: false, label: 'Buyer Name', if: proc { attributes[:user_id].blank? } do |order|
            (order[:buyer_name] || '').split('!!SEP!!').find(&:present?)
          end
        end

        table_column :purchase_state, filter: { type: :select, values: [%w(abandoned abandoned), [EffectiveOrders::PURCHASED, EffectiveOrders::PURCHASED], [EffectiveOrders::DECLINED, EffectiveOrders::DECLINED]], selected: EffectiveOrders::PURCHASED } do |order|
          order.purchase_state || 'abandoned'
        end

        table_column :order_items, sortable: false, column: 'order_items.title' do |order|
          content_tag(:ul) do
            (order[:order_items] || '').split('!!SEP!!').map { |oi| content_tag(:li, oi) }.join.html_safe
          end
        end

        table_column(:total) { |order| price_to_currency(order[:total].to_i) }
        table_column(:created_at, visible: false) { |order| order.updated_at.strftime('%Y-%m-%d %H:%M') }
        table_column(:updated_at, visible: false) { |order| order.updated_at.strftime('%Y-%m-%d %H:%M') }

        table_column :actions, sortable: false, filter: false do |order|
          link_to('View', (datatables_admin_path? ? effective_orders.admin_order_path(order) : effective_orders.order_path(order)))
        end

        def collection
          collection = Effective::Order.unscoped
                       .joins(:user, :order_items)
                       .group('users.email, orders.id')
                       .select('orders.*, users.email AS email')
                       .select("#{query_total} AS total")
                       .select("string_agg(order_items.title, '!!SEP!!') AS order_items")

          if EffectiveOrders.require_billing_address && defined?(EffectiveAddresses)
            addresses_tbl = EffectiveAddresses.addresses_table_name

            collection = collection
                         .joins("LEFT JOIN (SELECT addressable_id, string_agg(#{addresses_tbl}.full_name, '!!SEP!!') AS buyer_name FROM #{addresses_tbl} WHERE #{addresses_tbl}.category = 'billing' AND #{addresses_tbl}.addressable_type = 'Effective::Order' GROUP BY #{addresses_tbl}.addressable_id) #{addresses_tbl} ON orders.id = #{addresses_tbl}.addressable_id")
                         .group("#{addresses_tbl}.buyer_name")
                         .select("#{addresses_tbl}.buyer_name AS buyer_name")
          end

          attributes[:user_id].present? ? collection.where(user_id: attributes[:user_id]) : collection
        end

        def query_total
          'SUM((order_items.price * order_items.quantity) + (CASE order_items.tax_exempt WHEN true THEN 0 ELSE ((order_items.price * order_items.quantity) * order_items.tax_rate) END))'
        end

        def search_column(collection, table_column, search_term)
          if table_column[:name] == 'total'
            collection.having("#{query_total} = ?", (search_term.gsub(/[^0-9.]/, '').to_f * 100.0).to_i)
          elsif table_column[:name] == 'purchase_state' && search_term == 'abandoned'
            collection.where(purchase_state: nil)
          else
            super
          end
        end
      end
    end
  end
end
