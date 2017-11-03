module MnoEnterprise::Concerns::Controllers::Jpi::V1::Impac::KpisController
  extend ActiveSupport::Concern

  #==================================================================
  # Included methods
  #==================================================================
  # 'included do' causes the included code to be evaluated in the
  # context where it is included rather than being executed in the module's context
  included do
    respond_to :json

    before_filter :find_valid_kpi, only: [:update, :delete]
  end

  #==================================================================
  # Instance methods
  #==================================================================
  # GET /mnoe/jpi/v1/impac/kpis
  # This action is used as a sort of 'proxy' for retrieving KPI templates which are
  # usually retrieved from Impac! API, and customising the attributes.
  def index
    # Retrieve kpis templates from impac api.
    # TODO: improve request params to work for strong parameters
    attrs = params.slice('metadata', 'opts')
    auth = { username: MnoEnterprise.tenant_id, password: MnoEnterprise.tenant_key }

    begin
      # TODO check there was no error, something like
      # return render json: { message: "Unable to retrieve kpis from Impac API | Error #{response.code}" } unless response.success?
      response = MnoEnterprise::ImpacClient.send_get('/api/v2/kpis', attrs, basic_auth: auth)
    rescue => e
      return render json: { message: "Unable to retrieve kpis from Impac API | Error #{e}" }
    end

    # customise available kpis
    kpis = response['kpis'].to_a.map do |kpi|
      kpi = kpi.with_indifferent_access
      kpi[:watchables].map do |watchable|
        kpi.merge(
          name: "#{kpi[:name]} #{watchable.capitalize unless kpi[:name].downcase.index(watchable)}".strip,
          watchables: [watchable],
          target_placeholders: { watchable => kpi[:target_placeholders][watchable] },
        )
      end
    end.flatten

    render json: { kpis: kpis }
  end

  # POST /mnoe/jpi/v1/impac/dashboards/:dashboard_id/kpis
  #   -> POST /api/mnoe/v1/dashboards/:id/kpis
  #   -> POST /api/mnoe/v1/users/:id/alerts
  def create
    if params[:kpi][:widget_id].present?
      return render_not_found('widget') if widget.blank?
      authorize! :manage_widget, widget
    else
      return render_not_found('dashboard') if dashboard.blank?
      authorize! :manage_dashboard, dashboard
    end
    @kpi = MnoEnterprise::Kpi.create!(kpi_create_params)
    # Creates a default alert for kpis created with targets defined.
    if kpi.targets.present?
      MnoEnterprise::Alert.create_with_recipients!({ service: 'inapp', kpi_id: kpi.id }, [current_user.id])
      # TODO: should widget KPIs create an email alert automatically?
      MnoEnterprise::Alert.create_with_recipients!({ service: 'email', kpi_id: kpi.id }, [current_user.id]) if widget.present?
      # TODO: reload is adding the recipients to the kpi alerts (making another request).
    end
    @kpi = kpi.load_required(:alerts, :'alerts.recipients')
    render 'show'
  end

  # PUT /mnoe/jpi/v1/impac/kpis/:id
  #   -> PUT /api/mnoe/v1/kpis/:id
  def update
    return render_not_found('kpi') unless kpi.present?

    authorize! :manage_kpi, kpi

    params = kpi_update_params

    # TODO: refactor into models
    # --
    # Creates an in-app alert if target is set for the first time (in-app alerts should be activated by default)
    if kpi.targets.blank? && params[:targets].present?
      MnoEnterprise::Alert.create_with_recipients!({ service: 'inapp', kpi_id: kpi.id }, [current_user.id])
      # If targets have changed, reset all the alerts 'sent' status to false.
    elsif kpi.targets && params[:targets].present? && params[:targets] != kpi.targets
      kpi.alerts.each { |alert| alert.update_attributes(sent: false) }
      # Removes all the alerts if the targets are removed (kpi has no targets set,
      # and params contains no targets to be set)
    elsif params[:targets].blank? && kpi.targets.blank?
      kpi.alerts.each(&:destroy!)
    end
    kpi.update_attributes!(kpi_update_params)
    @kpi = kpi.load_required(:dashboard, :alerts, :'alerts.recipients')
    render 'show'
  end

  # DELETE /mnoe/jpi/v1/impac/kpis/:id
  #   -> DELETE /api/mnoe/v1/kpis/:id
  def destroy
    return render_not_found('kpi') unless kpi.present?
    authorize! :manage_kpi, kpi
    MnoEnterprise::EventLogger.info('kpi_delete', current_user.id, 'KPI Deletion', kpi)
    kpi.destroy!
    head status: :ok
  end

  #=================================================
  # Private methods
  #=================================================
  private

  def dashboard
    @dashboard ||= MnoEnterprise::Dashboard.find_one(params.require(:dashboard_id))
  end

  def widget
    widget_id = params.require(:kpi)[:widget_id]
    @widget ||= (widget_id.present? && MnoEnterprise::Widget.find_one(widget_id.to_i))
  end

  def kpi
    @kpi ||= MnoEnterprise::Kpi.find_one(params[:id], :dashboard, :widget, :alerts, :'alerts.recipients')
  end

  def kpi_create_params
    whitelist = [:widget_id, :endpoint, :source, :element_watched, { extra_watchables: [] }]
    create_params = extract_params(whitelist)
    #either it is a widget kpi or a dashboard kpi
    if create_params[:widget_id]
      create_params
    else
      create_params.merge(dashboard_id: params[:dashboard_id])
    end
  end

  def kpi_update_params
    whitelist = [:name, :element_watched, { extra_watchables: [] }]
    extract_params(whitelist)
  end

  def extract_params(whitelist)
    (p = params).require(:kpi).permit(*whitelist).tap do |whitelisted|
      whitelisted[:settings] = p[:kpi][:metadata] || {}
      # TODO: strong params for targets & extra_params attributes (keys will depend on the kpi).
      whitelisted[:targets] = p[:kpi][:targets] unless p[:kpi][:targets].blank?
      whitelisted[:extra_params] = p[:kpi][:extra_params] unless p[:kpi][:extra_params].blank?
    end.except(:metadata)
  end

  alias :find_valid_kpi :kpi

end
