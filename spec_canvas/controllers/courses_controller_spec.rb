#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of the analytics engine

require File.expand_path(File.dirname(__FILE__) + '/../../../../../spec/spec_helper')

describe CoursesController, :type => :controller do
  before :each do
    @account = Account.default
    @account.allowed_services = '+analytics'
    @account.save!

    # give all teachers in the account canvalytics permissions for now
    RoleOverride.manage_role_override(@account, 'TeacherEnrollment', 'view_analytics', :override => true)
  end

  context "permissions" do
    before :each do
      course_with_teacher(:active_all => true)
      student_in_course(:active_all => true)
      user_session(@teacher)
    end

    def expect_injection(opts={})
      course = opts[:course] || @course
      get 'show', :id => course.id
      assigns(:js_env).has_key?(:ANALYTICS).should be_true
      assigns(:js_env)[:ANALYTICS].should == { :link => "/courses/#{course.id}/analytics" }
    end

    def forbid_injection(opts={})
      course = opts[:course] || @course
      get 'show', :id => course.id
      assigns(:js_env).try(:has_key?, :ANALYTICS).should be_false
    end

    it "should inject an analytics button under nominal conditions" do
      expect_injection
    end

    it "should not inject an analytics button with analytics disabled" do
      @account.allowed_services = '-analytics'
      @account.save!
      forbid_injection
    end

    it "should not inject an analytics button on an unpublished course" do
      @course.workflow_state = 'created'
      @course.save!
      forbid_injection
    end

    it "should not inject an analytics button on an unreadable course" do
      @course1 = @course
      course_with_teacher(:active_all => true)
      user_session(@teacher)
      forbid_injection(:course => @course1)
    end

    it "should still inject an analytics button on a concluded course" do
      # teachers viewing analytics for a concluded course is currently
      # broken. so let an admin try it.
      user_session(account_admin_user)
      @course.complete!
      expect_injection
    end

    it "should not inject an analytics button without the analytics permission" do
      RoleOverride.manage_role_override(@account, 'TeacherEnrollment', 'view_analytics', :override => false)
      forbid_injection
    end

    it "should not inject an analytics button without the read_as_admin permission" do
      RoleOverride.manage_role_override(@account, 'StudentEnrollment', 'view_analytics', :override => true)
      user_session(@student)
      forbid_injection
    end

    it "should not inject an analytics button without active/completed enrollments in the course" do
      @enrollment.workflow_state = 'invited'
      @enrollment.save!
      forbid_injection
    end
  end
end
