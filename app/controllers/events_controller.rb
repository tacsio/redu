class EventsController < BaseController
  require 'htmlentities'
	
  layout 'environment'
  load_and_authorize_resource :environment
  load_and_authorize_resource :space
  load_and_authorize_resource :event, :through => [:space, :environment]

  before_filter :find_environment_course_and_space

  caches_page :ical
  cache_sweeper :event_sweeper, :only => [:create, :update, :destroy]
  before_filter :is_event_approved,
    :only => [:show, :edit, :update, :destroy]
  after_filter :create_activity, :only => [:create]

  #These two methods make it easy to use helpers in the controller.
  #This could be put in application_controller.rb if we want to use
  #helpers in many controllers
  def help
    Helper.instance
  end

  class Helper
    include Singleton
    include ActionView::Helpers::SanitizeHelper
    extend ActionView::Helpers::SanitizeHelper::ClassMethods
  end

  uses_tiny_mce(:options => AppConfig.simple_mce_options, :only => [:new, :edit, :create, :update])

  def ical
    @calendar = Icalendar::Calendar.new
    @calendar.custom_property('x-wr-caldesc',"#{AppConfig.community_name} #{:events.l}")
    Event.find(:all).each do |event|
      ical_event = Icalendar::Event.new
      ical_event.start = event.start_time.strftime("%Y%m%dT%H%M%S")
      ical_event.end = event.end_time.strftime("%Y%m%dT%H%M%S")
      #ical_event.summary = event.name + (event.metro_area.blank? ? '' : " (#{event.metro_area})")
      coder = HTMLEntities.new
      ical_event.description = (event.description.blank? ? '' : coder.decode(help.strip_tags(event.description).to_s) + "\n\n") + event_url(event)
      ical_event.location = event.location unless event.location.blank?
      @calendar.add ical_event
    end
    @calendar.publish
    headers['Content-Type'] = "text/calendar; charset=UTF-8"
    render :text => @calendar.to_ical, :layout => false
  end

  def show
    @eventable = find_eventable
  end

  def index
    @eventable = find_eventable
    @events = Event.approved.upcoming.paginate(:conditions => ["eventable_id = ?" \
                                               " AND eventable_type LIKE ?",
                                               @eventable.id,
                                               @eventable.class.to_s],
                                               :include => :owner,
                                               :page => params[:page],
                                               :order => 'start_time',
                                               :per_page => AppConfig.items_per_page)

    @list_title = "Eventos Futuros"
  end

  def past
    @eventable = find_eventable
    @events = Event.approved.past.paginate(:conditions => ["eventable_id = ?" \
                                  " AND eventable_type LIKE ?",
                                  @eventable.id,
                                  @eventable.class.to_s],
                                  :include => :owner,
                                  :page => params[:page],
                                  :order => 'start_time DESC',
                                  :per_page => AppConfig.items_per_page)

    @list_title = "Eventos Passados"
    render :template => 'events/index'
  end

  def new
    @eventable = find_eventable
  end

  def edit
    @eventable = find_eventable
 end

  def create
    # Passando para o formato do banco

    params[:event][:start_time] = Time.zone.parse(params[:event][:start_time].gsub('/', '-'))
    params[:event][:end_time] = Time.zone.parse(params[:event][:end_time].gsub('/', '-'))

    #FIXME o Event.new está sendo chamado duas vezes, uma vez pelo cancan e o outro aqui
    @event = Event.new(params[:event])

    @event.owner = current_user
    @event.eventable = find_eventable

    respond_to do |format|
      if @event.save

        if @event.owner.can_manage? @event
          @event.approve!
          flash[:notice] = "O evento foi criado e divulgado."
        else
          flash[:notice] = "O evento foi criado e será divulgado assim que for aprovado pelo moderador."
        end

        format.html { redirect_to polymorphic_path([@event.eventable, @event]) }
        format.xml  { render :xml => @event, :status => :created, :location => @event }
      else
        format.html { render :action => "new" }
        format.xml  { render :xml => @event.errors, :status => :unprocessable_entity }
      end
    end
  end

  def update
    # Passando para o formato do banco
    params[:event][:start_time] = Time.zone.parse(params[:event][:start_time].gsub('/', '-'))
    params[:event][:end_time] = Time.zone.parse(params[:event][:end_time].gsub('/', '-'))

    @event = Event.find(params[:id])
    respond_to do |format|
      if @event.update_attributes(params[:event])
        flash[:notice] = 'O evento foi editado.'
        format.html { redirect_to polymorphic_path([@event.eventable, @event]) }
        format.xml { render :xml => @event, :status => :created, :location => @event }
      else
        format.html { render :action => :edit }
        format.xml { render :xml => @event.errors, :status => :unprocessable_entity }
      end
    end
  end

  def destroy
    @event = Event.find(params[:id])
    @event.destroy

    respond_to do |format|
      flash[:notice] = 'O evento foi excluído.'
      format.html { redirect_to polymorphic_path(@event.eventable) }
    end
  end

  def vote
    @event = Event.find(params[:id])
    current_user.vote(@event, params[:like])
    respond_to do |format|
      format.js { render :template => 'shared/like', :locals => {:votes_for => @event.votes_for().to_s} }
    end
  end

  def day
    day = Time.utc(Time.now.year, Time.now.month, params[:day])

    @eventable = find_eventable
    @events = Event.approved.paginate(:conditions => ["eventable_id = ?" \
                             " AND eventable_type LIKE ?" \
                             " AND ? BETWEEN start_time AND end_time",
                             @eventable.id,
                             @eventable.class.to_s, day],
                             :include => :owner,
                             :page => params[:page],
                             :order => 'start_time DESC',
                             :per_page => AppConfig.items_per_page)

    @list_title = "Eventos do dia #{day.strftime("%d/%m/%Y")}"
    render :template => 'events/index'
  end

  def notify
    event = Event.find(params[:id])
    notification_time = event.start_time - params[:days].to_i.days
    Delayed::Job.enqueue(EventMailingJob.new(current_user, event), nil, notification_time)
    #TODO Verificar se a prioridade nil (zero) pode trazer problemas
    flash[:notice] = "Sua notificação foi agendada."

    redirect_to polymorphic_path([event.eventable, event])
  end

  protected
  def is_event_approved
    @event = Event.find(params[:id])

    if not @event.state == "approved"
      redirect_to polymorphic_path([@event.eventable])
    end
  end

  def find_eventable
    Space.find(params[:space_id]) if params[:space_id]
  end

  def find_environment_course_and_space
    if params[:space_id]
      @space = Space.find(params[:space_id])
      @course = @space.course
      @environment = @course.environment
    end
  end
end

