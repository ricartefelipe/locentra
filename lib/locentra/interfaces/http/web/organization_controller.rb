# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        # Organização: página com configurações, assinatura e filiais; tela de configurações (nome, fuso,
        # validade padrão do bloqueio e política de cancelamento) com pré-visualização e restauração dos
        # valores padrão; detalhe, edição, desativação e reativação de filiais.
        class OrganizationController < Controller
          POLICY = Domain::Organizations::CancellationPolicy
          SETTINGS_PATH = "/organizacao/configuracoes"
          SAVED = "Configurações salvas. Reservas, orçamentos e contratos já registrados mantêm a política e os valores do registro."
          DEACTIVATED = "Filial desativada. Reservas, orçamentos e contratos já registrados não mudam; ativos e estoque continuam vinculados " \
                        "e podem ser transferidos."

          # `values` são os dados enviados por uma criação de filial recusada.
          def show(ctx, errors: {}, status: 200, values: {})
            data = uc(:read_organization).call(ctx.actor)
            render(ctx, "organization/show", title: "Organização", status: status, data: data, errors: errors, values: values)
          end

          def create_branch(ctx)
            uc(:create_branch).call(ctx.actor, name: ctx.form["nome"], code: ctx.form["codigo"], address: ctx.form["endereco"])
            redirect(ctx, "/organizacao", notice: "Filial criada.")
          rescue Domain::ValidationError => e
            show(ctx, errors: e.errors, status: 422, values: ctx.form)
          rescue Domain::Conflict, Domain::PlanLimitExceeded => e
            field = e.is_a?(Domain::Conflict) && e.code == "duplicate_branch" ? "codigo" : "base"
            show(ctx, errors: { field => [e.message] }, status: 422, values: ctx.form)
          end

          # Sem `values`, os campos e a versão vêm do registro; com eles (prévia, restauração e recusa), tudo
          # vem do envio, inclusive a versão.
          def settings(ctx, errors: {}, status: 200, values: nil, preview: nil)
            data = uc(:get_organization_settings).call(ctx.actor)
            org = data[:organization]
            render(ctx, "organization/settings", title: "Configurações da organização", status: status, data: data, errors: errors,
                                                 values: values || settings_values(org), preview: preview || preview_of(org, org))
          end

          def update_settings(ctx)
            case ctx.form["acao"]
            when "previsualizar" then preview_settings(ctx)
            when "restaurar_padrao" then restore_defaults(ctx)
            else save_settings(ctx)
            end
          end

          def branch(ctx, errors: {}, status: 200, values: nil)
            data = uc(:get_branch).call(ctx.actor, ctx.param(:id))
            render(ctx, "organization/branch", title: "Filial #{data[:branch].code}", status: status, data: data, errors: errors, values: values)
          end

          def update_branch(ctx)
            f = ctx.form
            result = uc(:update_branch).call(ctx.actor, ctx.param(:id), name: f["nome"], address: f["endereco"], lock_version: f["versao"])
            redirect(ctx, branch_path(result.record), notice: result.changed ? "Filial atualizada." : "Nenhuma alteração a salvar.")
          rescue Domain::ValidationError => e
            branch(ctx, errors: e.errors, status: 422, values: ctx.form)
          rescue Domain::Conflict => e
            branch(ctx, errors: { "base" => [e.message] }, status: 409, values: e.code == "stale_branch" ? nil : ctx.form)
          end

          def deactivate_branch(ctx) = toggle_branch(ctx, false, DEACTIVATED, "A filial já estava inativa.")
          def reactivate_branch(ctx) = toggle_branch(ctx, true, "Filial reativada.", "A filial já estava ativa.")

          private

          def branch_path(branch) = "/organizacao/filiais/#{branch.id}"

          def toggle_branch(ctx, active, notice, unchanged)
            result = uc(:set_branch_active).call(ctx.actor, ctx.param(:id), active: active)
            redirect(ctx, branch_path(result.record), notice: result.changed ? notice : unchanged)
          rescue Domain::Conflict, Domain::PlanLimitExceeded => e
            branch(ctx, errors: { "base" => [e.message] }, status: 409)
          end

          def save_settings(ctx)
            result = uc(:update_organization_settings).call(ctx.actor, settings_attrs(ctx), lock_version: ctx.form["versao"])
            redirect(ctx, SETTINGS_PATH, notice: result.changed ? SAVED : "Nenhuma alteração a salvar.")
          rescue Domain::ValidationError => e
            settings(ctx, errors: e.errors, status: 422, values: submitted_values(ctx))
          rescue Domain::Conflict => e
            settings(ctx, errors: { "base" => [e.message] }, status: 409)
          end

          # Nada é gravado nem auditado. As faixas voltam na ordem canônica da prévia.
          def preview_settings(ctx)
            result = uc(:preview_organization_settings).call(ctx.actor, settings_attrs(ctx))
            revised = result[:revised]
            values = ctx.form.merge(policy_fields(revised.cancellation_policy))
            settings(ctx, values: values, preview: preview_of(result[:current], revised, confirmed: confirmed?(ctx)))
          rescue Domain::ValidationError => e
            settings(ctx, errors: e.errors, status: 422, values: submitted_values(ctx))
          end

          # Valores padrão da validade e da política nos campos, mantendo os demais valores e a versão enviados.
          def restore_defaults(ctx)
            values = ctx.form.merge("validade_bloqueio" => Domain::Organizations::Settings::DEFAULT_HOLD_MINUTES.to_s).merge(policy_fields(POLICY::DEFAULT))
            preview = { policy: POLICY::DEFAULT, hold_minutes: Domain::Organizations::Settings::DEFAULT_HOLD_MINUTES, comparison: nil }
            settings(ctx, values: values, preview: preview)
          end

          def confirmed?(ctx) = ctx.form["confirmar_fuso"] == "1"

          def settings_attrs(ctx)
            f = ctx.form
            { name: f["nome"], timezone: f["fuso_horario"], hold_minutes: f["validade_bloqueio"],
              cancellation_rows: paired(f["antecedencia_horas"], f["multa_percentual"]), confirm_timezone_change: confirmed?(ctx) }
          end

          def submitted_values(ctx)
            rows = POLICY.compact_rows(paired(ctx.form["antecedencia_horas"], ctx.form["multa_percentual"]))
            ctx.form.merge("antecedencia_horas" => rows.map(&:first), "multa_percentual" => rows.map(&:last))
          end

          def settings_values(org)
            { "nome" => org.name, "fuso_horario" => org.timezone, "validade_bloqueio" => org.hold_minutes.to_s,
              "versao" => org.lock_version.to_s }.merge(policy_fields(org.cancellation_policy))
          end

          def policy_fields(policy)
            tiers = POLICY.sorted(policy)
            { "antecedencia_horas" => tiers.map { |tier| tier.fetch("min_hours_before").to_s },
              "multa_percentual" => tiers.map { |tier| Domain::Percent.value(tier.fetch("fee_bps")) } }
          end

          # Pré-visualização: política, validade e, na troca de fuso, os dois fusos (a tela mostra o instante
          # atual em cada um).
          def preview_of(current, revised, confirmed: false)
            comparison = ({ from: current.time_zone, to: revised.time_zone, confirmed: confirmed } if current.timezone_changed?(revised))
            { policy: revised.cancellation_policy, hold_minutes: revised.hold_minutes, comparison: comparison }
          end
        end
      end
    end
  end
end
