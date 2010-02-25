require 'uuidtools'
class Event < ActiveRecord::Base
  include ActionView::Helpers::DateHelper

  belongs_to :created_by, :class_name => 'User'
  belongs_to :updated_by, :class_name => 'User'
  belongs_to :calendar
  is_site_scoped if respond_to? :is_site_scoped

  belongs_to :event_venue
  accepts_nested_attributes_for :event_venue, :reject_if => proc { |attrs| attrs.all? { |k, v| v.blank? } }

  has_many :occurrences, :class_name => 'EventOccurrence', :dependent => :destroy
  has_many :recurrence_rules, :class_name => 'EventRecurrenceRule', :dependent => :destroy
  accepts_nested_attributes_for :recurrence_rules, :allow_destroy => true#, :reject_if => lambda { |attributes| attributes['active'].to_s != '1' }

  validates_presence_of :uuid, :title, :start_date, :end_date, :status_id
  validates_uniqueness_of :uuid

  before_validation_on_create :get_uuid
  before_validation_on_create :set_default_status
  before_validation :set_default_end_date
  after_save :write_occurrences
  
  named_scope :imported, { :conditions => ["status_id = ?", Status[:imported].to_s] }
  named_scope :submitted, { :conditions => ["status_id = ?", Status[:submitted].to_s] }
  named_scope :approved, { :conditions => ["status_id >= (?)", Status[:published].to_s] }

  def location
    event_venue || read_attribute(:location)
  end

  def date
    start_date.to_datetime.strftime(date_format)
  end

  def short_date
    start_date.to_datetime.strftime(short_date_format)
  end
  
  def start_time
    start_date.to_datetime.strftime(start_date.min == 0 ? round_time_format : time_format).downcase
  end

  def end_time
    end_date.to_datetime.strftime(end_date.min == 0 ? round_time_format : time_format).downcase if end_date
  end
  
  def duration
    end_date - start_date
  end

  def starts
    if all_day?
      "all day"
    else
      start_time
    end
  end
  
  def finishes
    if end_date
      if within_day?
        end_time
      elsif all_day?
        "on #{end_date.to_datetime.strftime(short_date_format)}"
      else
        "#{end_time} on #{end_date.to_datetime.strftime(short_date_format)}"
      end
    end
  end
    
  def one_day?
    all_day? && within_day?
  end
  
  def within_day?
    (!end_date || start_date.to_date.jd == end_date.to_date.jd)
  end
  
  def editable?
    status != Status[:imported]
  end
  
  def status
    Status.find(self.status_id)
  end
  def status=(value)
    self.status_id = value.id
  end
  
  def recurrence
    recurrence_rules.first.to_s
  end
  
  def add_recurrence(rule)
    self.recurrence_rules << EventRecurrenceRule.from(rule)
  end
      
  def to_ri_cal
    RiCal.Event do |cal_event|
      cal_event.uid = uuid
      cal_event.summary = title
      cal_event.description = description if description
      cal_event.dtstart =  (all_day? ? start_date.to_date : start_date) if start_date
      cal_event.dtend = (all_day? ? end_date.to_date : end_date) if end_date
      cal_event.url = url if url
      cal_event.rrules = recurrence_rules.map(&:to_ical) if recurrence_rules.any?
      cal_event.location = location if location
    end
  end
  
  def ical
    self.to_ri_cal.to_s
  end
  
  def self.from(cal_event)
    event = new({
      :uuid => cal_event.uid,
      :title => cal_event.summary,
      :description => cal_event.description,
      :location => cal_event.location,
      :url => cal_event.url,
      :start_date => cal_event.dtstart,
      :end_date => cal_event.dtend,
      :all_day => !cal_event.dtstart.is_a?(DateTime)
    })
    event.status = Status[:imported]
    cal_event.rrule.each { |rule| event.add_recurrence(rule) }
    event
  rescue => error
    logger.error "Event import error: #{error}."
    raise
  end
  
protected

  def get_uuid
    self.uuid ||= UUIDTools::UUID.timestamp_create.to_s
  end

  def set_default_status
    self.status ||= Status[:Published]
  end
  
  def set_default_end_date
    if end_date.blank?
      default_duration = Radiant::Config['event_calendar.default_duration'] || 1.hour
      self.end_date = start_date + default_duration
    end
  end
  
  # doesn't yet observe exceptions
  def write_occurrences
    occurrences.clear
    occurrences.create
    if recurrence_rules.any?
      to_ri_cal.occurrences.each do |occ|
        occurrences.create(:start_date => occ.dtstart, :end_date => occ.dtend)
      end
    end
  end
  
  def date_format
    Radiant::Config['event_calendar.date_format'] || "%d %B %Y"
  end
  
  def short_date_format
    Radiant::Config['event_calendar.short_date_format'] || "%d/%m/%Y"
  end
  
  def time_format
    Radiant::Config['event_calendar.time_format'] || "%-1I:%M%p"
  end
  
  def round_time_format
    Radiant::Config['event_calendar.round_time_format'] || "%-1I%p"
  end

end
