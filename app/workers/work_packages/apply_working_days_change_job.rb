#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2012-2022 the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
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
# See COPYRIGHT and LICENSE files for more details.
#++

class WorkPackages::ApplyWorkingDaysChangeJob < ApplicationJob
  queue_with_priority :above_normal

  def perform(user_id:, previous_working_days:)
    user = User.find(user_id)

    User.execute_as user do
      updated_work_packages = []

      each_applicable_work_package(previous_working_days) do |work_package|
        updated_work_packages += apply_change_to_work_package(user, work_package)
      end
      each_applicable_follows_relation do |work_package|
        updated_work_packages += apply_change_to_predecessor(user, work_package)
      end

      set_journal_notice(updated_work_packages, previous_working_days)
    end
  end

  private

  def apply_change_to_work_package(user, work_package)
    WorkPackages::UpdateService
      .new(user:, model: work_package, contract_class: EmptyContract)
      .call(duration: work_package.duration) # trigger a recomputation of start and due date
      .all_results
  end

  def apply_change_to_predecessor(user, predecessor)
    # TODO: skip if included in work packages updated by apply_change_to_work_package
    schedule_result = WorkPackages::SetScheduleService
                        .new(user:, work_package: predecessor)
                        .call

    # The SetScheduleService does not save. It has to be done by the caller.
    schedule_result.dependent_results.map do |dependent_result|
      work_package = dependent_result.result
      work_package.save

      work_package
    end
  end

  def each_applicable_work_package(previous_working_days, &)
    changed_days = changed_days(previous_working_days)

    for_each_work_package_in_scope(WorkPackage
                                   .covering_days_of_week(changed_days)
                                   .order(WorkPackage.arel_table[:start_date].asc.nulls_first,
                                          WorkPackage.arel_table[:due_date].asc),
                                   &)
  end

  def changed_days(previous_working_days)
    previous = Set.new(previous_working_days)
    current = Set.new(Setting.working_days)

    # `^` is a Set method returning a new set containing elements exclusive to
    # each other
    (previous ^ current).to_a
  end

  def each_applicable_follows_relation(&)
    for_each_work_package_in_scope(WorkPackage
                                    .where(id: Relation.follows_with_delay.select(:to_id)),
                                   &)
  end

  def set_journal_notice(updated_work_packages, previous_working_days)
    day_changes = changed_days(previous_working_days).index_with { |day| Setting.working_days.include?(day) }
    journal_note = journal_notice_text(day_changes)

    updated_work_packages.uniq.each do |work_package|
      work_package.journal_notes = journal_note
      work_package.save
    end
  end

  def journal_notice_text(day_changes)
    I18n.with_locale(Setting.default_language) do
      I18n.t(:'working_days.journal_note.changed',
             changes: day_changes.collect { |day, working| working_day_change_message(day, working) }.join(', '))
    end
  end

  def working_day_change_message(day, working)
    I18n.t(:"working_days.journal_note.days.#{working ? :working : :non_working}",
           day: I18n.t('date.day_names')[day])
  end

  def for_each_work_package_in_scope(scope)
    scope.pluck(:id).each do |id|
      yield WorkPackage.find(id)
    end
  end
end
