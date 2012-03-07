#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of the analytics engine

require File.expand_path(File.dirname(__FILE__) + '/../../../../../../spec/apis/api_spec_helper')

describe "Analytics API", :type => :integration do

  before :each do
    @account = Account.default
    @account.allowed_services = '+analytics'
    @account.save!

    # give all teachers in the account canvalytics permissions for now
    RoleOverride.manage_role_override(@account, 'TeacherEnrollment', 'view_analytics', :override => true)
  end

  def analytics_api_call(action, course, student, opts={})
    action, endpoint =
      case action
      when :participation then ['user_in_course_participation', "/api/v1/analytics/participation/courses/#{course.id}/users/#{student.id}"]
      when :assignments then ['user_in_course_assignments', "/api/v1/analytics/assignments/courses/#{course.id}/users/#{student.id}"]
      when :messaging then ['user_in_course_messaging', "/api/v1/analytics/messaging/courses/#{course.id}/users/#{student.id}"]
      end

    api_call(:get,
          endpoint,
          { :controller => 'analytics_api',
            :action => action,
            :format => 'json',
            :course_id => course.id.to_s,
            :user_id => student.id.to_s },
          {}, {}, opts)
  end

  context "permissions" do
    before :each do
      @student1 = user(:active_all => true)
      course_with_teacher(:active_all => true)
      @default_section = @course.default_section
      @section = factory_with_protected_attributes(@course.course_sections, :sis_source_id => 'my-section-sis-id', :name => 'section2')
      @course.enroll_user(@student1, 'StudentEnrollment', :section => @section).accept!
    end

    # each of these is nominal aside from the condition in the description
    it "should 200 under nominal conditions" do
      analytics_api_call(:participation, @course, @student1, :expected_status => 200)
      analytics_api_call(:assignments, @course, @student1, :expected_status => 200)
      analytics_api_call(:messaging, @course, @student1, :expected_status => 200)
    end

    it "should 404 with analytics disabled" do
      @account.allowed_services = '-analytics'
      @account.save!

      analytics_api_call(:participation, @course, @student1, :expected_status => 404)
      analytics_api_call(:assignments, @course, @student1, :expected_status => 404)
      analytics_api_call(:messaging, @course, @student1, :expected_status => 404)
    end

    it "should 401 with unreadable course" do
      @course1 = @course
      course_with_teacher(:active_all => true)

      analytics_api_call(:participation, @course1, @student1, :expected_status => 401)
      analytics_api_call(:assignments, @course1, @student1, :expected_status => 401)
      analytics_api_call(:messaging, @course1, @student1, :expected_status => 401)
    end

    it "should 401 with out analytics permission" do
      RoleOverride.manage_role_override(@account, 'TeacherEnrollment', 'view_analytics', :override => false)

      analytics_api_call(:participation, @course, @student1, :expected_status => 401)
      analytics_api_call(:assignments, @course, @student1, :expected_status => 401)
      analytics_api_call(:messaging, @course, @student1, :expected_status => 401)
    end

    it "should 404 with unreadable user" do
      # section limited ta in section other than student1
      @ta = user(:active_all => true)
      @enrollment = @course.enroll_ta(@ta)
      @enrollment.course = @course # set the reverse association
      @enrollment.workflow_state = 'active'
      @enrollment.limit_privileges_to_course_section = true
      @enrollment.course_section = @default_section
      @enrollment.save!

      RoleOverride.manage_role_override(@account, 'TaEnrollment', 'view_analytics', :override => true)

      analytics_api_call(:participation, @course, @student1, :expected_status => 404)
      analytics_api_call(:assignments, @course, @student1, :expected_status => 404)
      analytics_api_call(:messaging, @course, @student1, :expected_status => 404)
    end
  end

  context "course and quiz with a submitted score" do
    before do
      @student1 = user(:active_all => true)
      course_with_teacher(:active_all => true)
      @default_section = @course.default_section
      @section = factory_with_protected_attributes(@course.course_sections, :sis_source_id => 'my-section-sis-id', :name => 'section2')
      @course.enroll_user(@student1, 'StudentEnrollment', :section => @section).accept!

      quiz = Quiz.create!(:title => 'quiz1', :context => @course, :points_possible => 10)
      quiz.did_edit!
      quiz.offer!
      @a1 = quiz.assignment
      sub = @a1.find_or_create_submission(@student1)
      sub.submission_type = 'online_quiz'
      sub.workflow_state = 'submitted'
      sub.score = 9
      sub.save!
      @submitted_at = sub.submitted_at
    end

    it "should include student data" do
      json = analytics_api_call(:assignments, @course, @student1)
      json.should == [{
        "title" => @a1.title,
        "assignment_id" => @a1.id,
        "max_score" => 9,
        "first_quartile" => 9,
        "median" => 9,
        "third_quartile" => 9,
        "unlock_at" => nil,
        "min_score" => 9,
        "due_at" => nil,
        "points_possible" => 0,
        "submission" => {
          "submitted_at" => @submitted_at.iso8601,
          "score" => 9
        }
      }]
    end
  end

  context "course multiple assignements with a multiple users and scores" do
    before do
      num_users = 5
      num_assignments = 5

      @students = []
      @assignments = []
      @outcomes = []
      
      num_users.times {|u| @students << user(:active_all => true)}

      course_with_teacher(:active_all => true)
      @default_section = @course.default_section
      @section = factory_with_protected_attributes(@course.course_sections, :sis_source_id => 'my-section-sis-id', :name => 'section2')

      @students.each {|s| @course.enroll_user(s, 'StudentEnrollment', :section => @section).accept!}

      @due_time ||= Time.now.utc

      num_assignments.times{|i| @assignments << Assignment.create!(
          :title => "assignment #{i + 1}",
          :context => @course,
          :points_possible => 10 * (i+1),
          :due_at => @due_time)}

      for s_index in 0..(num_users - 1)
        student = @students[s_index]
        for a_index in 0..(num_assignments - 1)
          assignment = @assignments[a_index]
          @outcomes[a_index] = @course.learning_outcomes.create!
          @tag = @outcomes[a_index].align(assignment, @course, :mastery_type => "points")
          assignment.reload
          grade = (10 * (a_index + 1)) - s_index * (a_index+1)
          sub = assignment.grade_student(student, :grade => grade).first
          sub.submission_type = 'online_text_entry'
          if a_index > 0
            sub.submitted_at = @due_time - 3.hours + s_index.hours
          end
          if a_index < 4
            sub.graded_at = @due_time + 6.days - a_index.days
          end
          sub.save!
        end
      end
    end

    def response_assignment(json, assignment)
      json_assignment = json.detect{ |a| a["assignment_id"] == assignment.id }
      json_assignment.should_not be_nil
      json_assignment
    end

    it "should fetch data for a student in the course" do
      json = analytics_api_call(:assignments, @course, @students[1])
    end

    it "should calculate max score" do
      json = analytics_api_call(:assignments, @course, @students[1])
      response_assignment(json, @assignments[3])["max_score"].should == 40
    end

    it "should calculate min score" do
      json = analytics_api_call(:assignments, @course, @students[1])
      response_assignment(json, @assignments[4])["min_score"].should == 30
    end

    it "should calculate first quartile of scores" do
      json = analytics_api_call(:assignments, @course, @students[1])
      response_assignment(json, @assignments[0])["first_quartile"].should == 6.5
    end

    it "should calculate median of scores" do
      json = analytics_api_call(:assignments, @course, @students[1])
      response_assignment(json, @assignments[0])["median"].should == 8
    end

    it "should calculate third quartile of scores" do
      json = analytics_api_call(:assignments, @course, @students[1])
      response_assignment(json, @assignments[0])["third_quartile"].should == 9.5
    end

    it "should have the user score" do
      json = analytics_api_call(:assignments, @course, @students[1])
      response_assignment(json, @assignments[2])["submission"]["score"].should == 27
    end

    it "should have the user submit time" do
      json = analytics_api_call(:assignments, @course, @students[1])
      response_assignment(json, @assignments[4])["submission"]["submitted_at"].should == (@due_time - 2.hours).iso8601
    end

    it "should track due dates" do
      json = analytics_api_call(:assignments, @course, @students[1])
      response_assignment(json, @assignments[3])["due_at"].should == @due_time.iso8601
    end
  end

end