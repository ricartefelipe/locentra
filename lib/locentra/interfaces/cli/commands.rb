# frozen_string_literal: true

require_relative "output"
require_relative "command_support"
require_relative "commercial_terms_commands"

module Locentra
  module Interfaces
    module CLI
      # Comandos da CLI operacional. Cada comando chama somente casos de uso da aplicação, com o ator
      # autenticado pela credencial: autorização, revalidação da credencial, isolamento por
      # organização e auditoria são os mesmos da interface web e da API.
      class Commands
        include CommandSupport

        F = Formatting
        S = Serializers
        HOLDS = { "inspection" => "inspeção pendente", "maintenance" => "ordem de manutenção ativa" }.freeze
        REPORT_STATUSES = { "running" => "Em execução", "completed" => "Concluída", "failed" => "Falhou" }.freeze
        ERROR_WIDTH = 100
        DISCREPANCY_HEADERS = ["Tipo", "Pagamento", "No provedor", "Situação local", "Situação no provedor", "Valor local", "Valor no provedor",
                               "Ação"].freeze

        def initialize(system:, actor:)
          @system = system
          @actor = actor
        end

        # Os comandos de condições comerciais (cupons, tarifas e condições negociadas) ficam em classe própria.
        def run(invocation)
          return CommercialTermsCommands.new(system: @system, actor: @actor).run(invocation) if CommercialTermsCommands.handles?(invocation.command.handler)

          options = invocation.options
          argument = invocation.argument
          case invocation.command.handler
          when :whoami then whoami
          when :availability then availability(options)
          when :reservations_list then reservations_list(options)
          when :reservations_show then reservations_show(argument)
          when :asset_show then asset_show(argument)
          when :finance_reconcile then finance_reconcile
          when :jobs_failures then jobs_failures(options)
          when :jobs_retry then jobs_retry(argument)
          end
        end

        private

        def whoami
          info = uc(:whoami).call(@actor)
          org = info[:organization]
          credential = info[:credential]
          scopes = info[:actor].scopes.sort
          data = { "actor_type" => info[:actor].kind, "organization" => S.organization(org),
                   "credential" => S.credential(credential).merge("scopes" => scopes) }
          Result.ok(data, ["Credencial: #{F.clean(credential["name"])} (tipo #{credential["kind"]}, id #{credential["id"]})",
                           "Organização: #{F.clean(org.name)} (#{org.slug}) · fuso #{org.timezone}",
                           "Escopos: #{scopes.join(", ")}",
                           "Válida até: #{F.time(credential["expires_at"], org.time_zone)} · " \
                           "último uso: #{F.time(credential["last_used_at"], org.time_zone)}"])
        end

        def availability(options)
          branch = pick_branch(options[:branch])
          period = Domain::Period.new(instant(options[:starts], "inicio"), instant(options[:ends], "fim"))
          ids, skus = split_products(options[:products])
          rows = uc(:check_availability).call(@actor, branch_id: branch.id, period: period, product_ids: ids, skus: skus)
          missing = Array(ids) - rows.map { |row| row["product"].id }
          raise Domain::ValidationError.field("produto", "não encontrado: #{missing.join(", ")}") unless missing.empty?

          data = { "branch" => S.branch(branch), "period" => period.to_h, "time_zone" => zone.identifier,
                   "data" => rows.map { |row| availability_row(row) } }
          header = "Disponibilidade na filial #{branch.code} (#{F.clean(branch.name)}), período #{F.period(period, zone)}"
          table = rows.map do |row|
            product = row["product"]
            [product.sku, product.name, Domain::Catalog::TRACKING.fetch(product.tracking), row["available"], row["total"]]
          end
          lines = rows.empty? ? ["Nenhum produto encontrado."] : F.table(%w[SKU Produto Rastreamento Disponível Total], table)
          Result.ok(data, [header, "", *lines])
        end

        def availability_row(row)
          product = row["product"]
          { "product_id" => product.id, "sku" => product.sku, "name" => product.name, "tracking" => product.tracking,
            "available" => row["available"], "total" => row["total"] }
        end

        def reservations_list(options)
          from = options[:from] && instant(options[:from], "de")
          to = options[:to] && instant(options[:to], "ate")
          raise Domain::ValidationError.field("ate", "deve ser posterior a --de") if from && to && to <= from

          page = uc(:list_reservations).call(@actor, status: options[:status], customer_id: options[:customer], search: options[:search],
                                                     from: from, to: to, sort: options[:sort] || "-starts_at", limit: options[:limit],
                                                     offset: options[:offset])
          names = Application::Reservations::ListReservations.customer_names?(@actor)
          data = { "data" => page.items.map { |row| reservation_row(row, names) }, "pagination" => pagination(page) }
          Result.ok(data, reservation_lines(page, names))
        end

        # Sem `customers.read`, a chave `customer_name` é omitida (como `customer.name` em `show`).
        def reservation_row(row, names)
          base = S.reservation(row[:reservation])
          names ? base.merge("customer_name" => row[:customer_name]) : base
        end

        def reservation_lines(page, names)
          return ["Nenhuma reserva encontrada."] if page.items.empty?

          rows = page.items.map do |row|
            r = row[:reservation]
            [r.code, r.status_label, names ? row[:customer_name] : r.customer_id, F.time(r.period.starts_at, zone), F.time(r.period.ends_at, zone),
             r.total.format_brl]
          end
          lines = [*F.table(["Código", "Situação", names ? "Cliente" : "Cliente (id)", "Retirada", "Devolução", "Total"], rows), "", shown_line(page)]
          names ? lines : lines + ["Nomes de clientes omitidos: a credencial não tem customers.read."]
        end

        def reservations_show(reference)
          details = uc(:get_reservation).by_reference(@actor, reference)
          reservation = details[:reservation]
          customer = customer_summary(reservation.customer_id)
          branch = organization[:branches].find { |b| b.id == reservation.branch_id }
          data = { "reservation" => S.reservation(reservation).merge("notes" => reservation.notes), "customer" => customer,
                   "branch" => S.branch(branch), "items" => details[:items].map { |item| reservation_item(item) },
                   "allocations" => reservation_allocations(details[:allocations]) }
          Result.ok(data, reservation_detail_lines(reservation, customer, branch, details))
        end

        # O nome do cliente exige `customers.read`; sem o escopo, apenas o identificador é exibido.
        def customer_summary(customer_id)
          return { "id" => customer_id } unless Application::Authorizer.allowed?(@actor, "customers.read")

          { "id" => customer_id, "name" => uc(:get_customer).call(@actor, customer_id)[:customer].name }
        end

        def reservation_item(item)
          { "product_id" => item["product_id"], "sku" => item["sku"], "name" => item["name"], "tracking" => item["tracking"],
            "quantity" => item["quantity"], "total" => S.money(item["total_cents"]) }
        end

        def reservation_allocations(allocations)
          assets = allocations[:assets].map do |a|
            { "asset_id" => a["asset_id"], "tag" => a["tag"], "serial_number" => a["serial_number"], "product_id" => a["product_id"],
              "asset_status" => a["asset_status"], "active" => a["active"], "period" => S.allocation_period(a) }
          end
          stock = allocations[:stock].map do |s|
            { "stock_pool_id" => s["stock_pool_id"], "product_id" => s["product_id"], "quantity" => s["quantity"], "active" => s["active"],
              "period" => S.allocation_period(s) }
          end
          { "assets" => assets, "stock" => stock }
        end

        def reservation_detail_lines(reservation, customer, branch, details)
          lines = ["Reserva #{reservation.code} · #{reservation.status_label}",
                   "Cliente: #{customer["name"] ? "#{F.clean(customer["name"])} (id #{customer["id"]})" : "id #{customer["id"]}"}",
                   "Filial: #{branch ? "#{branch.code} (#{F.clean(branch.name)})" : reservation.branch_id}",
                   "Período: #{F.period(reservation.period, zone)}",
                   "Total: #{reservation.total.format_brl} · caução: #{reservation.deposit.format_brl} · origem: #{reservation.source}"]
          lines << "Bloqueio temporário até: #{F.time(reservation.hold_expires_at, zone)}" if reservation.held?
          lines << "Observações: #{F.clean(reservation.notes)}" if reservation.notes
          items = details[:items].map { |i| [i["sku"], i["name"], i["quantity"], F.money(i["total_cents"])] }
          lines += ["", "Itens:", *F.table(%w[SKU Produto Quantidade Total], items)]
          lines + ["", "Alocações:", *allocation_lines(details[:allocations])]
        end

        def allocation_lines(allocations)
          rows = allocations[:assets].map { |a| ["ativo #{a["tag"]}", 1, F.time(a["starts_at"], zone), F.time(a["ends_at"], zone), F.yes_no(a["active"])] } +
                 allocations[:stock].map { |s| ["estoque", s["quantity"], F.time(s["starts_at"], zone), F.time(s["ends_at"], zone), F.yes_no(s["active"])] }
          return ["  nenhuma (a alocação ocorre na confirmação)"] if rows.empty?

          F.table(%w[Recurso Quantidade Início Fim Ativa], rows)
        end

        def asset_show(reference)
          details = uc(:get_asset).by_reference(@actor, reference)
          asset = details[:asset]
          product = details[:product]
          branch = organization[:branches].find { |b| b.id == asset.branch_id }
          data = { "asset" => asset_data(asset, branch, details[:hold]),
                   "product" => { "id" => product.id, "sku" => product.sku, "name" => product.name, "tracking" => product.tracking },
                   "allocations" => details[:allocations].map { |a| asset_allocation(a) },
                   "history" => details[:events].map { |e| asset_event(e) } }
          Result.ok(data, asset_lines(asset, product, branch, details))
        end

        def asset_data(asset, branch, hold)
          { "id" => asset.id, "tag" => asset.tag, "serial_number" => asset.serial_number, "status" => asset.status,
            "status_label" => asset.status_label, "condition" => asset.condition, "condition_label" => asset.condition_label,
            "branch" => S.branch(branch), "unavailable_until" => S.time(asset.unavailable_until), "operational_hold" => hold,
            "allocatable" => asset.allocatable?, "operationally_blocked" => asset.operationally_blocked? }
        end

        # Novas alocações: baixado/extraviado nunca; em inspeção, manutenção ou trânsito somente após
        # `unavailable_until` (sem data, até a conclusão da operação), como no motor de disponibilidade.
        def allocation_policy(asset)
          return "não (#{asset.status_label.downcase})" unless asset.allocatable?
          return "sim" unless asset.operationally_blocked?
          return "a partir de #{F.time(asset.unavailable_until, zone)}" if asset.unavailable_until

          "não, até a conclusão da operação"
        end

        def asset_allocation(row)
          reservation = row["reservation_id"] && { "id" => row["reservation_id"], "code" => row["reservation_code"], "status" => row["reservation_status"] }
          { "id" => row["id"], "kind" => row["kind"], "reason" => row["reason"], "active" => row["active"], "period" => S.allocation_period(row),
            "reservation" => reservation }
        end

        def asset_event(row)
          { "kind" => row["kind"], "from_status" => row["from_status"], "to_status" => row["to_status"], "from_branch_id" => row["from_branch_id"],
            "to_branch_id" => row["to_branch_id"], "reference_type" => row["reference_type"], "reference_id" => row["reference_id"],
            "notes" => row["notes"], "occurred_at" => S.time(row["occurred_at"]) }
        end

        def asset_lines(asset, product, branch, details)
          lines = ["Ativo #{asset.tag} · #{asset.status_label}", "Produto: #{product.sku} #{F.clean(product.name)}", "", "Situação física:",
                   "  Situação: #{asset.status_label} · condição: #{asset.condition_label} · série: #{F.clean(asset.serial_number)}",
                   "  Filial atual: #{branch ? "#{branch.code} (#{F.clean(branch.name)})" : asset.branch_id}",
                   "  Aceita novas alocações: #{allocation_policy(asset)}"]
          lines << "  Controle operacional: #{HOLDS.fetch(details[:hold])}" if details[:hold]
          lines + ["", "Alocações e bloqueios (horários em #{zone.identifier}):", *asset_allocation_lines(details[:allocations]),
                   "", "Histórico:", *asset_history_lines(details[:events])]
        end

        def asset_allocation_lines(rows)
          return ["  nenhuma"] if rows.empty?

          table = rows.map do |a|
            kind = a["kind"] == "block" ? "bloqueio: #{a["reason"]}" : "reserva"
            reservation = a["reservation_code"] ? "#{a["reservation_code"]} (#{Domain::Reservations::STATUSES.fetch(a["reservation_status"])})" : "—"
            [F.time(a["starts_at"], zone), F.time(a["ends_at"], zone), kind, reservation, F.yes_no(a["active"])]
          end
          F.table(%w[Início Fim Tipo Reserva Ativa], table)
        end

        def asset_history_lines(events)
          return ["  sem eventos"] if events.empty?

          table = events.map do |e|
            change = e["to_status"] ? "#{e["from_status"] || "—"} → #{e["to_status"]}" : "—"
            [F.time(e["occurred_at"], zone), e["kind"], change, e["notes"]]
          end
          F.table(%w[Quando Evento Situação Observações], table)
        end

        # O relatório exige `finance.read`: conferido antes de executar, para não conciliar sem poder exibir.
        def finance_reconcile
          Application::Authorizer.authorize!(@actor, "finance.read")
          result = uc(:reconcile_payments).call(@actor)
          if result == :no_account
            raise Domain::ValidationError.field("provedor", "nenhuma conta de provedor de pagamentos ativa; configure-a em Financeiro > Provedor")
          end

          report = uc(:finance).report(@actor, result)
          data = { "report" => report_data(report[:report]), "items" => report[:items].map { |item| report_item(item) } }
          failed = report[:report]["status"] == "failed"
          Result.new(data: data, lines: report_lines(report), exit_code: failed ? ExitCodes::UNAVAILABLE : ExitCodes::OK)
        end

        def report_data(report)
          { "id" => report["id"], "provider" => report["provider"], "status" => report["status"], "window_start" => S.time(report["window_start"]),
            "started_at" => S.time(report["started_at"]), "finished_at" => S.time(report["finished_at"]), "summary" => report["summary"] || {},
            "error" => report["error"] }
        end

        def report_item(item)
          { "kind" => item["kind"], "payment_id" => item["payment_id"], "provider_payment_id" => item["provider_payment_id"],
            "external_reference" => item["external_reference"], "local_status" => item["local_status"], "remote_status" => item["remote_status"],
            "local_amount" => S.money(item["local_amount_cents"]), "remote_amount" => S.money(item["remote_amount_cents"]), "action" => item["action"] }
        end

        def report_lines(data)
          report = data[:report]
          lines = ["Conciliação #{report["id"]} · #{REPORT_STATUSES.fetch(report["status"])}",
                   "Provedor: #{Domain::Finance::PROVIDERS.fetch(report["provider"], report["provider"])} · pagamentos e cobranças desde " \
                   "#{F.time(report["window_start"], zone)} (#{zone.identifier})"]
          return lines + ["Falha na consulta ao provedor: #{F.clean(report["error"])}. Nenhuma alteração foi feita."] if report["status"] == "failed"

          summary = report["summary"] || {}
          lines << "Pagamentos verificados: #{summary["checked"]} · divergências: #{data[:items].size}"
          lines << "A listagem do provedor veio incompleta; ausências avaliadas só para pagamentos consultados." if summary["complete"] == false
          return lines + ["", "Nenhuma divergência encontrada."] if data[:items].empty?

          lines + ["", *F.table(DISCREPANCY_HEADERS, data[:items].map { |item| discrepancy_row(item) })]
        end

        def discrepancy_row(item)
          fin = Domain::Finance
          [fin::Reconciliation::KINDS.fetch(item["kind"]), item["payment_id"] || item["external_reference"], item["provider_payment_id"],
           item["local_status"] && fin::PAYMENT_STATUSES.fetch(item["local_status"], item["local_status"]),
           item["remote_status"] && fin::REMOTE_STATUSES.fetch(item["remote_status"], item["remote_status"]),
           F.money(item["local_amount_cents"]), F.money(item["remote_amount_cents"]), fin::Reconciliation::ACTIONS.fetch(item["action"])]
        end

        def jobs_failures(options)
          rows = uc(:list_failed_jobs).call(@actor, limit: options[:limit])
          data = { "data" => rows.map { |row| job_failure(row) } }
          return Result.ok(data, ["Nenhuma tarefa morta."]) if rows.empty?

          table = rows.map do |r|
            [r["id"], r["kind"], "#{r["attempts"]}/#{r["max_attempts"]}", F.time(r["updated_at"], zone), F.truncate(r["last_error"], ERROR_WIDTH)]
          end
          Result.ok(data, ["Tarefas mortas (#{rows.size}), horários em #{zone.identifier}:", "",
                           *F.table(%w[Id Tipo Tentativas Atualizada Erro], table), "",
                           "Reprocessar: bin/locentra jobs retry ID"])
        end

        def job_failure(row)
          { "id" => row["id"], "kind" => row["kind"], "attempts" => row["attempts"], "max_attempts" => row["max_attempts"], "last_error" => row["last_error"],
            "correlation_id" => row["correlation_id"], "created_at" => S.time(row["created_at"]), "updated_at" => S.time(row["updated_at"]),
            "finished_at" => S.time(row["finished_at"]) }
        end

        def jobs_retry(job_id)
          job = uc(:retry_job).call(@actor, job_id)
          Result.ok({ "job" => job }, ["Tarefa #{job["id"]} (#{job["kind"]}) reenfileirada para reprocessamento.",
                                       "Tentativas anteriores: #{job["previous_attempts"]}. A operação foi registrada na auditoria."])
        end

        def pick_branch(reference)
          branches = organization[:branches]
          codes = branches.select(&:active).map(&:code).sort
          if reference.nil?
            return branches.find(&:active) if codes.size == 1

            raise UsageError, "informe --filial (códigos: #{codes.join(", ")})"
          end
          text = reference.strip
          branches.find { |b| b.id == text.downcase || b.code == text.upcase } ||
            raise(Domain::ValidationError.field("filial", "não encontrada (códigos: #{codes.join(", ")})"))
        end

        # Identificadores e SKUs informados em --produto; nil quando a opção não foi usada.
        def split_products(values)
          return [nil, nil] if values.nil?

          list = values.map(&:strip).reject(&:empty?)
          raise UsageError, "informe ao menos um produto em --produto" if list.empty?

          list.partition { |value| Domain::Identifier.valid?(value) }.then { |ids, skus| [ids.map(&:downcase), skus] }
        end
      end
    end
  end
end
