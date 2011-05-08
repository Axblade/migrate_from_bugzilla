# redMine - project management software
# Copyright (C) 2006-2007  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# Bugzilla migration by Arjen Roodselaar, Lindix bv
#
# Custom field migration code was added y Eugene Sypachev, St.Petersburg, Russia
#

desc 'Bugzilla migration script'

require 'active_record'
require 'iconv'
require 'pp'

module ActiveRecord
  namespace :redmine do
    task :migrate_from_bugzilla => :environment do

      module AssignablePk        
        attr_accessor :pk
        def set_pk
          self.id = self.pk unless self.pk.nil?
        end
      end

      def self.register_for_assigned_pk(klasses)
        klasses.each do |klass|
          klass.send(:include, AssignablePk)
          klass.send(:before_create, :set_pk)
        end
      end

      register_for_assigned_pk([User, Project, Issue, IssueCategory, Attachment, Version])

      module BugzillaMigrate 
        DEFAULT_STATUS = IssueStatus.default
        CLOSED_STATUS = IssueStatus.find_by_position(5)
        assigned_status = IssueStatus.find_by_position(2)
        resolved_status = IssueStatus.find_by_position(3)
        feedback_status = IssueStatus.find_by_position(4)
      
        STATUS_MAPPING = {
          "UNCONFIRMED" => DEFAULT_STATUS,
          "NEW" => DEFAULT_STATUS,
          "VERIFIED" => assigned_status,
          "ASSIGNED" => assigned_status,
          "REOPENED" => assigned_status,
          "RESOLVED" => resolved_status,
          "CLOSED" => CLOSED_STATUS
	  	  
        }
        # actually close resolved issues
        resolved_status.is_closed = true
        resolved_status.save
                        
        priorities = IssuePriority.all(:order => 'id')
        PRIORITY_MAPPING = {
          "P5" => priorities[0], # low
          "P4" => priorities[1], # normal
          "P3" => priorities[2], # high
          "P2" => priorities[3], # urgent
          "P1" => priorities[4]  # immediate
        }
        DEFAULT_PRIORITY = PRIORITY_MAPPING["P5"]
    
        TRACKER_BUG = Tracker.find_by_position(1)
        TRACKER_FEATURE = Tracker.find_by_position(2)
      
        reporter_role = Role.find_by_position(5)
        developer_role = Role.find_by_position(4)
        manager_role = Role.find_by_position(3)
        DEFAULT_ROLE = reporter_role
      
        CUSTOM_FIELD_TYPE_MAPPING = {
          0 => 'string', # String
          1 => 'int',    # Numeric
          2 => 'int',    # Float
          3 => 'list',   # Enumeration
          4 => 'string', # Email
          5 => 'bool',   # Checkbox
          6 => 'list',   # List
          7 => 'list',   # Multiselection list
          8 => 'date',   # Date
        }
                                   
        RELATION_TYPE_MAPPING = {
          0 => IssueRelation::TYPE_DUPLICATES, # duplicate of
          1 => IssueRelation::TYPE_RELATES,    # related to
          2 => IssueRelation::TYPE_RELATES,    # parent of
          3 => IssueRelation::TYPE_RELATES,    # child of
          4 => IssueRelation::TYPE_DUPLICATES  # has duplicate
        }


	# list of values for bugzilla Severity field
	# values must be equal to bugzilla values
	# othervise value will be blank
	SEVERITY_LIST = ["blocker", "critical", "enhansement", "normal", "major", "minor", "trivial"]
		
		# custom field list
		# values for text field:
		# [position, name_of_redmine_field, name_of_bugzilla_field, "text", min_length, max_length]
		# values for list field:
		# [position, name_of_redmine_field, name_of_bugzilla_field, "text", min_length, max_length, list_of_bugzilla_values]
		# list must be defined above, like "SEVERITY LIST"
        CUSTOM_FIELDS = [[1, "Bugzilla ID", "id", "text", 0, 0],
			[2, "Severity", "bug_severity", "list", 0, 0, SEVERITY_LIST]]

	class BugzillaProfile < ActiveRecord::Base
          set_table_name :profiles
          set_primary_key :userid
        
          has_and_belongs_to_many :groups,
            :class_name => "BugzillaGroup",
            :join_table => :user_group_map,
            :foreign_key => :user_id,
            :association_foreign_key => :group_id
        
          def login
            login_name[0..50].gsub(/[^a-zA-Z0-9_\-@\.]/, '-') # it was 29
          end
        
          def email
            if login_name.match(/^.*@.*$/i)
              login_name
            else
              "#{login_name}@foo.bar"
            end
          end
        
          def lastname
            s = read_attribute(:realname)
            return 'unknown' if(s.blank?)
            return s.split(/[ ,]+/)[-1]
          end

          def firstname
            s = read_attribute(:realname)
            return 'unknown' if(s.blank?)
            return s.split(/[ ,]+/).first
          end
        end
      
        class BugzillaGroup < ActiveRecord::Base
          set_table_name :groups
        
          has_and_belongs_to_many :profiles,
            :class_name => "BugzillaProfile",
            :join_table => :user_group_map,
            :foreign_key => :group_id,
            :association_foreign_key => :user_id
        end
      
        class BugzillaProduct < ActiveRecord::Base
          set_table_name :products
        
          has_many :components, :class_name => "BugzillaComponent", :foreign_key => :product_id
          has_many :versions, :class_name => "BugzillaVersion", :foreign_key => :product_id
          has_many :bugs, :class_name => "BugzillaBug", :foreign_key => :product_id
        end
      
        class BugzillaComponent < ActiveRecord::Base
          set_table_name :components
        end
      
        class BugzillaVersion < ActiveRecord::Base
          set_table_name :versions
        end
      
        class BugzillaBug < ActiveRecord::Base
          set_table_name :bugs
          set_primary_key :bug_id
        
          belongs_to :product, :class_name => "BugzillaProduct", :foreign_key => :product_id
          has_many :descriptions, :class_name => "BugzillaDescription", :foreign_key => :bug_id
          has_many :attachments, :class_name => "BugzillaAttachment", :foreign_key => :bug_id
        end

        class BugzillaDependency < ActiveRecord::Base
          set_table_name :dependencies
        end
        
        class BugzillaDuplicate < ActiveRecord::Base
          set_table_name :duplicates
        end

        class BugzillaDescription < ActiveRecord::Base
          set_table_name :longdescs
          set_inheritance_column :bongo
          belongs_to :bug, :class_name => "BugzillaBug", :foreign_key => :bug_id
        
          def eql(desc)
            self.bug_when == desc.bug_when
          end
        
          def === desc
            self.eql(desc)
          end
        
          def text
            if self.thetext.blank?
              return nil
            else
              self.thetext
            end
          end
        end

        class BugzillaAttachment < ActiveRecord::Base
          set_table_name :attachments
          set_primary_key :attach_id

          has_one :attach_data, :class_name => 'BugzillaAttachData', :foreign_key => :id


          def size
            return 0 if self.attach_data.nil?
            return self.attach_data.thedata.size
          end

          def original_filename
            return self.filename
          end

          def content_type
            self.mimetype
          end

          def read(*args)
            if @read_finished
              nil
            else
              @read_finished = true
              return nil if self.attach_data.nil?
              return self.attach_data.thedata
            end
          end
        end

        class BugzillaAttachData < ActiveRecord::Base
          set_table_name :attach_data
        end

      
        def self.establish_connection(params)
          constants.each do |const|
            klass = const_get(const)
            next unless klass.respond_to? 'establish_connection'
            klass.establish_connection params
          end
        end
       
	    # 1 journal entry is formed for all custom fields
		def self.create_journal_string(bug)
			journal_string = ""
			CUSTOM_FIELDS.each do |entity|
				journal_string += "Value of custom field #{entity[1]} was #{bug.instance_variable_get("@" + entity[2].to_s)}.\n" unless entity[2].blank?
			end
			return journal_string
		end
 
        def self.map_user(userid)
            @user_map[userid]
        end
		
		def self.map_category(catid)
			@category_map[catid]
		end

	

        def self.migrate_users
          puts "Migrating profiles\n"
          
          # bugzilla userid => redmine user pk.  Use email address
          # as the matching mechanism.  If profile exists in redmine,
          # leave it untouched, otherwise create a new user and copy
          # the profile data from bugzilla
          
          @user_map = {}
          BugzillaProfile.all(:order => :userid).each do |profile|
            profile_email = profile.email
            profile_email.strip!
            existing_redmine_user = User.find_by_mail(profile_email)
            if existing_redmine_user
              @user_map[profile.userid] = existing_redmine_user.id
            else
              # create the new user with its own fresh pk
              # and make an entry in the mapping
              user = User.new
              user.login = profile.login
              user.password = "bugzilla"
              user.firstname = profile.firstname
              user.lastname = profile.lastname
              user.mail = profile.email
              user.mail.strip!
              user.status = User::STATUS_LOCKED if !profile.disabledtext.empty?
              user.admin = true if profile.groups.include?(BugzillaGroup.find_by_name("admin"))
	      unless user.save then
                puts "FAILURE saving user"
                puts "user: #{user.inspect}"
                puts "bugzilla profile: #{profile.inspect}"
                validation_errors = user.errors.collect {|e| e.to_s }.join(", ")
                puts "validation errors: #{validation_errors}" 
              end
              @user_map[profile.userid] = user.id
            end
          end
          puts '.'
          $stdout.flush
        end
        
        def self.migrate_products
          puts "Migrating products"
          
          @project_map = {}
          
          BugzillaProduct.find_each do |product|
            project = Project.new
            # project.pk = product.id
            project.id = product.id
		project.name = product.name
            project.description = product.description
         
		print "Please, enter identifier for project #{product.name} (default will be project and id string)"
		identifier_value = STDIN.gets
	unless identifier_value.blank?
		project.identifier = identifier_value
	else
		project.identifier = "project" + "#{product.id}"
	end

            unless project.save 
				puts "Failure saving product"
				puts "product: #{product.name}"
				validation_errors = product.errors.collect { |e| e.to_s}.join(", ")
				puts "validation errors: #{validation_errors}"
			end
            puts product.name + " saved"
            @project_map[product.id] = project.id
            
			
            product.versions.each do |version|
              unless Version.create(:name => version.value, :project => project) then
			  	puts "Failure saving version"
				puts "product: #{product.name}"
				puts "version: #{product.version.value}"
				validation_errors = product.version.errors.collect { |e| e.to_s}.join(", ")
				puts "validation errors: #{validation_errors}"
			  end
			  #puts version.value + " saved"
            end
            
            # Enable issue tracking
            enabled_module = EnabledModule.new(
              :project => project,
              :name => 'issue_tracking'
            )
            enabled_module.save
			
            # Components
            @category_map = {}
            product.components.each do |component|
              
				category = IssueCategory.new(:name => component.name[0,50]) 
				category.project = project
				uid = map_user(component.initialowner)
				category.id = component.id
				category.assigned_to = User.first(:conditions => {:id => uid })
				category.save

				@category_map[component.id] = category.id          
			end


            User.find_each do |user|
              membership = Member.new(
                :user => user,
                :project => project                
              )
              membership.roles << DEFAULT_ROLE
              membership.save
            end
          
          end
			puts "."
			$stdout.flush
        end

        def self.migrate_issues()
          puts "Migrating issues"
          
          # Issue.destroy_all
          @issue_map = {}
          
          BugzillaBug.find(:all, :order => :bug_id).each  do |bug|

            puts "Processing bugzilla bug #{bug.bug_id}"
            description = bug.descriptions.first.text.to_s

            issue = Issue.new(
              :project_id => @project_map[bug.product_id],
              :subject => bug.short_desc,
              :description => description || bug.short_desc,
              :author_id => map_user(bug.reporter),
              :priority => PRIORITY_MAPPING[bug.priority] || DEFAULT_PRIORITY,
              :status => STATUS_MAPPING[bug.bug_status] || DEFAULT_STATUS,
              :start_date => bug.creation_ts,
              :created_on => bug.creation_ts,
              :updated_on => bug.delta_ts
		)
           
	   
            issue.tracker = TRACKER_BUG
	   
	    issue.category_id = bug.component_id unless bug.component_id.blank?

            issue.assigned_to_id = map_user(bug.assigned_to) unless bug.assigned_to.blank?
            version = Version.first(:conditions => {:project_id => @project_map[bug.product_id], :name => bug.version })
            issue.fixed_version = version
           
            issue.save!
            #puts "Redmine issue number is #{issue.id}"
            @issue_map[bug.bug_id] = issue.id
            
            
            bug.descriptions.each do |description|
              # the first comment is already added to the description field of the bug
              next if description === bug.descriptions.first
              journal = Journal.new(
                :journalized => issue,
                :user_id => map_user(description.who),
                :notes => description.text,
                :created_on => description.bug_when
              )
              journal.save!
            end

            # Add a journal entry to capture the original bugzilla bug ID
            journal = Journal.new(
              :journalized => issue,
              :user_id => 1,
              :notes => "#{create_journal_string(bug)}"
            )
            journal.save!

 # Additionally save the original bugzilla bug ID as custom field value.

		# moves values from bugzilla custom fields to new redmine fileds
		# bugzilla custom field values are found by name of custom field (for example cf_time)
		# redmine fields are found with position identifier
		CUSTOM_FIELDS.each do |entity|
			issue.custom_field_values = {entity[0] => "#{bug.instance_variable_get("@" + entity[2].to_s)}"} unless (bug.instance_variable_get("@" + entity[2].to_s)).blank?
		end
	    issue.save_custom_field_values

            print '.'
            $stdout.flush
          end
        end
        
        def self.migrate_attachments()
          puts  "Migrating attachments"
          BugzillaAttachment.find_each() do |attachment|
            next if attachment.attach_data.nil?
            a = Attachment.new :created_on => attachment.creation_ts
            a.file = attachment
            a.author = User.find(map_user(attachment.submitter_id)) || User.first
            a.container = Issue.find(@issue_map[attachment.bug_id])
            a.save

            print '.'
            $stdout.flush
          end
        end

        def self.migrate_issue_relations()
          puts "Migrating issue relations"
          BugzillaDependency.find_by_sql("select blocked, dependson from dependencies").each do |dep|
            rel = IssueRelation.new
            rel.issue_from_id = @issue_map[dep.blocked]
            rel.issue_to_id = @issue_map[dep.dependson]
            rel.relation_type = "blocks"
            rel.save
            print '.'
            $stdout.flush
          end

          BugzillaDuplicate.find_by_sql("select dupe_of, dupe from duplicates").each do |dup|
            rel = IssueRelation.new
            rel.issue_from_id = @issue_map[dup.dupe_of]
            rel.issue_to_id = @issue_map[dup.dupe]
            rel.relation_type = "duplicates"
            rel.save
            print '.'
            $stdout.flush
          end
        end

	
	# method for creating redmine custom text fields
	def self.create_custom_text_field(position, field_name, min_length, max_length)
		custom = IssueCustomField.find_by_name(field_name)
		return if custom
		custom = IssueCustomField.new({:regexp => "",
					:position => position,
					:name => field_name,
					:is_required => false,
					:min_length => min_length,
					:default_value => "",
					:searchable => true,
					:is_for_all => true,
					:max_length => max_length,
					:is_filter => true,
					:editable => true,
					:field_format => "string"})
		custom.save!
		
		Tracker.all.each do |t|
			t.custom_fields << custom
			t.save!
		end
		puts "Custom field #{field_name} was created!"
	end 

    # method for creating redmine custom list fields
	def self.create_custom_list_field(position, field_name, possible_values)
		custom = IssueCustomField.find_by_name(field_name)
		return if custom
		custom = IssueCustomField.new({:regexp => "",
					:position => position,
					:name => field_name,
					:is_required => false,
					:possible_values => possible_values,
					:default_value => "",
					:searchable => true,
					:is_for_all => true,
					:is_filter => true,
					:editable => true,
					:field_format => "list"})
		custom.save!

		Tracker.all.each do |t|
			t.custom_fields << custom
			t.save!
		end
		puts "Custom field #{field_name} was created!"
	end

        puts
        puts "WARNING: Your Redmine data could be corrupted during this process."
        print "Are you sure you want to continue ? [y/N] "
        break unless STDIN.gets.match(/^y$/i)
      
        # Default Bugzilla database settings
        db_params = {:adapter => 'mysql',
          :database => 'bugs',
          :host => 'localhost',
          :port => 3306,
		  :socket => '/var/run/mysqld/mysqld.sock',
          :username => 'root',
          :password => '123456',
          :encoding => 'utf8'}

        puts
        puts "Please enter settings for your Bugzilla database"
        [:adapter, :host, :port, :database, :socket, :username, :password].each do |param|
            print "#{param} [#{db_params[param]}]: "
            value = STDIN.gets.chomp!
            value = value.to_i if param == :port
            db_params[param] = value unless value.blank?
        end

        # Make sure bugs can refer bugs in other projects
        Setting.cross_project_issue_relations = 1 if Setting.respond_to? 'cross_project_issue_relations'

        # Turn off email notifications
        Setting.notified_events = []

     
        BugzillaMigrate.establish_connection db_params
        
		#create custom fields
		CUSTOM_FIELDS.each do |entity|
			BugzillaMigrate.create_custom_text_field(entity[0], entity[1], entity[4], entity[5]) if entity[3] == "text"
			BugzillaMigrate.create_custom_list_field(entity[0], entity[1], entity[6]) if entity[3] == "list"
		end

		BugzillaMigrate.migrate_users
        BugzillaMigrate.migrate_products
        BugzillaMigrate.migrate_issues
        BugzillaMigrate.migrate_attachments
        BugzillaMigrate.migrate_issue_relations
 
      end   
    end
  end
end
