# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        class IntegrationsController < Controller
          def index(ctx, errors: {}, status: 200, secret: nil)
            data = uc(:list_webhooks).call(ctx.actor)
            render(ctx, "integrations/index", title: "Integrações", status: status, data: data, errors: errors, secret: secret,
                                              events: Application::Webhooks::EVENTS)
          end

          def create(ctx)
            row = uc(:create_webhook).call(ctx.actor, url: ctx.form["url"], events: Array(ctx.form["eventos"]), description: ctx.form["descricao"])
            index(ctx, secret: row["secret"])
          rescue Domain::ValidationError, Domain::PlanLimitExceeded, Domain::EmailUnconfirmed => e
            index(ctx, errors: e.is_a?(Domain::ValidationError) ? e.errors : { "base" => [e.message] }, status: 422)
          end

          def disable(ctx)
            uc(:disable_webhook).call(ctx.actor, ctx.param(:id))
            redirect(ctx, "/integracoes", notice: "Endpoint desativado.")
          end

          # Reativação de endpoint pausado pelo circuito; as entregas retidas saem em segundo plano.
          def resume(ctx)
            result = uc(:resume_webhook).call(ctx.actor, ctx.param(:id))
            redirect(ctx, "/integracoes", notice: "Endpoint reativado. Entregas retidas a reenviar em segundo plano: #{result["held_deliveries"]}.")
          rescue Domain::Conflict, Domain::EmailUnconfirmed => e
            redirect(ctx, "/integracoes", alert: e.message)
          end

          def redeliver(ctx)
            uc(:redeliver_webhook).call(ctx.actor, ctx.param(:id))
            redirect(ctx, "/integracoes", notice: "Reenvio agendado.")
          rescue Domain::Conflict, Domain::EmailUnconfirmed => e
            redirect(ctx, "/integracoes", alert: e.message)
          end
        end

        # Anexos: upload validado por conteúdo e download autenticado (nunca servidos como estáticos).
        class AttachmentsController < Controller
          RETURN_PATHS = {
            "customer" => "/clientes/%s", "contract" => "/contratos/%s", "damage_report" => "/operacao/avarias/%s",
            "return" => "/operacao", "maintenance_order" => "/manutencao/%s", "quote" => "/orcamentos/%s"
          }.freeze

          def create(ctx)
            file = ctx.form["arquivo"]
            owner_type = ctx.form["dono_tipo"].to_s
            owner_id = ctx.form["dono_id"].to_s
            back = format(RETURN_PATHS.fetch(owner_type, "/"), Domain::Identifier.parse(owner_id, "dono"))
            return redirect(ctx, back, alert: "Selecione um arquivo.") unless file.is_a?(Hash) && file[:tempfile]

            bytes = file[:tempfile].read(@system.config.max_upload_bytes + 1)
            uc(:upload_attachment).call(ctx.actor, owner_type: owner_type, owner_id: owner_id, filename: file[:filename], bytes: bytes)
            redirect(ctx, back, notice: "Anexo enviado.")
          rescue Domain::ValidationError, Domain::Conflict => e
            redirect(ctx, back || "/", alert: "Anexo recusado: #{e.message}")
          ensure
            file[:tempfile].close! if file.is_a?(Hash) && file[:tempfile].respond_to?(:close!)
          end

          def show(ctx)
            row, bytes = uc(:download_attachment).call(ctx.actor, ctx.param(:id))
            [200, {
              "content-type" => row["content_type"],
              "content-disposition" => disposition(row["filename"], row["content_type"]),
              "content-length" => bytes.bytesize.to_s,
              "cache-control" => "private, no-store",
              "content-security-policy" => "default-src 'none'; sandbox",
              "x-content-type-options" => "nosniff"
            }, [bytes]]
          end

          def remove(ctx)
            uc(:remove_attachment).call(ctx.actor, ctx.param(:id))
            redirect(ctx, ctx.form["voltar"].to_s.start_with?("/") ? ctx.form["voltar"] : "/", notice: "Anexo removido.")
          rescue Domain::Conflict => e
            redirect(ctx, ctx.form["voltar"].to_s.start_with?("/") ? ctx.form["voltar"] : "/", alert: e.message)
          end

          private

          def disposition(filename, content_type)
            content_disposition(filename, content_type == "application/pdf" || content_type.start_with?("image/") ? "inline" : "attachment")
          end
        end
      end
    end
  end
end
