# frozen_string_literal: true

module Locentra
  module Application
    module Customers
      class CreateCustomer
        def initialize(uow:, customers:, audit:, clock:, ids:)
          @uow = uow
          @customers = customers
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, attrs)
          @uow.run(actor, "customers.write") do |tx, current|
            customer = Domain::Customers::Customer.build(
              id: @ids.uuid, organization_id: tx.tenant_id!, kind: attrs[:kind].to_s, name: attrs[:name], document: attrs[:document],
              trade_name: attrs[:trade_name], email: attrs[:email], phone: attrs[:phone], notes: attrs[:notes]
            )
            raise Domain::Conflict.new("já existe cliente com este documento", code: "duplicate_document") if @customers.document_taken?(
              tx, customer.document
            )

            @customers.insert(tx, customer, @clock.now)
            @audit.record(tx, current, "customer.created", "customer", customer.id, "kind" => customer.kind)
            customer
          end
        end
      end

      class UpdateCustomer
        EDITABLE = %i[name trade_name email phone notes status].freeze

        def initialize(uow:, customers:, audit:, clock:)
          @uow = uow
          @customers = customers
          @audit = audit
          @clock = clock
        end

        def call(actor, customer_id, attrs)
          @uow.run(actor, "customers.write") do |tx, current|
            customer = @customers.lock(tx, Domain::Identifier.parse(customer_id)) || raise(Domain::NotFound, "cliente")
            status = attrs.fetch(:status, customer.status).to_s
            raise Domain::ValidationError.field("situacao", "inválida") unless Domain::Customers::STATUSES.key?(status)

            updated = Domain::Customers::Customer.build(
              id: customer.id, organization_id: customer.organization_id, kind: customer.kind, document: customer.document,
              name: attrs.fetch(:name, customer.name), trade_name: attrs.fetch(:trade_name, customer.trade_name),
              email: attrs.fetch(:email, customer.email), phone: attrs.fetch(:phone, customer.phone), notes: attrs.fetch(:notes, customer.notes)
            ).with(status: status)
            @customers.update(tx, updated, @clock.now)
            changed = EDITABLE.reject { |field| updated.public_send(field) == customer.public_send(field) }
            @audit.record(tx, current, "customer.updated", "customer", customer.id, "fields" => changed.map(&:to_s))
            updated
          end
        end
      end

      class AddContact
        def initialize(uow:, customers:, audit:, clock:, ids:)
          @uow = uow
          @customers = customers
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, customer_id, attrs)
          @uow.run(actor, "customers.write") do |tx, current|
            customer = @customers.find(tx, Domain::Identifier.parse(customer_id)) || raise(Domain::NotFound, "cliente")
            contact = Domain::Customers::Contact.build(
              id: @ids.uuid, organization_id: tx.tenant_id!, customer_id: customer.id, name: attrs[:name], email: attrs[:email],
              phone: attrs[:phone], role: attrs[:role], document: attrs[:document], authorized_pickup: attrs[:authorized_pickup] ? true : false
            )
            @customers.insert_contact(tx, contact, @clock.now)
            @audit.record(tx, current, "customer.contact_added", "customer", customer.id, "authorized_pickup" => contact.authorized_pickup)
            contact
          end
        end
      end

      class AddAddress
        def initialize(uow:, customers:, audit:, clock:, ids:)
          @uow = uow
          @customers = customers
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, customer_id, attrs)
          @uow.run(actor, "customers.write") do |tx, current|
            customer = @customers.find(tx, Domain::Identifier.parse(customer_id)) || raise(Domain::NotFound, "cliente")
            address = Domain::Customers::Address.build(id: @ids.uuid, organization_id: tx.tenant_id!, customer_id: customer.id, **attrs.slice(
              :label, :street, :number, :complement, :district, :city, :state, :postal_code
            ).compact)
            @customers.insert_address(tx, address, @clock.now)
            @audit.record(tx, current, "customer.address_added", "customer", customer.id)
            address
          end
        end
      end

      class ListCustomers
        def initialize(uow:, customers:)
          @uow = uow
          @customers = customers
        end

        def call(actor, search: nil, status: nil, sort: "name", limit: nil, offset: nil)
          lim, off = Page.params(limit: limit, offset: offset)
          @uow.run(actor, "customers.read") do |tx, _current|
            items, total = @customers.search(tx, search: search.to_s.strip[0, 100], status: status, sort: sort, limit: lim, offset: off)
            Page.new(items: items, limit: lim, offset: off, total: total)
          end
        end
      end

      class GetCustomer
        def initialize(uow:, customers:)
          @uow = uow
          @customers = customers
        end

        def call(actor, customer_id)
          @uow.run(actor, "customers.read") do |tx, current|
            id = Domain::Identifier.parse(customer_id)
            raise Domain::NotFound, "cliente" if current.customer? && current.customer_id != id

            customer = @customers.find(tx, id) || raise(Domain::NotFound, "cliente")
            { customer: customer, contacts: @customers.contacts(tx, id), addresses: @customers.addresses(tx, id) }
          end
        end
      end
    end
  end
end
