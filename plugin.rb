# frozen_string_literal: true

# name: discourse-translator
# about: Provides inline translation of posts.
# version: 0.3.0
# authors: Alan Tan, Ace Stream
# url: https://github.com/acestream/discourse-translator

gem 'aws-sdk-translate', '1.35.0', require: false

enabled_site_setting :translator_enabled
register_asset "stylesheets/common/post.scss"

after_initialize do
  module ::DiscourseTranslator
    PLUGIN_NAME = "discourse_translator".freeze
    DETECTED_LANG_CUSTOM_FIELD = 'post_detected_lang'.freeze
    TRANSLATED_CUSTOM_FIELD = 'translated_text'.freeze

    autoload :Microsoft, "#{Rails.root}/plugins/discourse-translator/services/discourse_translator/microsoft"
    autoload :Google, "#{Rails.root}/plugins/discourse-translator/services/discourse_translator/google"
    autoload :Amazon, "#{Rails.root}/plugins/discourse-translator/services/discourse_translator/amazon"
    autoload :Yandex, "#{Rails.root}/plugins/discourse-translator/services/discourse_translator/yandex"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseTranslator
    end
  end

  require_dependency "application_controller"
  class DiscourseTranslator::TranslatorController < ::ApplicationController

    def translate
      raise PluginDisabled if !SiteSetting.translator_enabled

      if !SiteSetting.translator_enabled_for_guests
        ensure_logged_in
      end

      if current_user and !current_user.staff?
        # Limit requests for non-staff users
        RateLimiter.new(current_user, "translate_post", SiteSetting.max_translations_per_minute, 1.minute).performed!
      end

      params.require(:post_id)
      post = Post.find_by(id: params[:post_id])
      raise Discourse::InvalidParameters.new(:post_id) if post.blank?
      guardian.ensure_can_see!(post)

      if SiteSetting.translator_max_post_length > 0 and post.cooked.length > SiteSetting.translator_max_post_length
        render_json_error "Post is too long for translation", status: 422
        return
      end

      begin
        detected_lang, translation = "DiscourseTranslator::#{SiteSetting.translator}".constantize.translate(post)
        render json: { translation: translation, detected_lang: detected_lang }, status: 200
      rescue ::DiscourseTranslator::TranslatorError => e
        render_json_error e.message, status: 422
      end
    end
  end

  Post.register_custom_field_type(::DiscourseTranslator::TRANSLATED_CUSTOM_FIELD, :json)

  require_dependency "post"
  class ::Post < ActiveRecord::Base
    before_update :clear_translator_custom_fields, if: :raw_changed?

    private

    def clear_translator_custom_fields
      return if !SiteSetting.translator_enabled

      self.custom_fields.delete(DiscourseTranslator::DETECTED_LANG_CUSTOM_FIELD)
      self.custom_fields.delete(DiscourseTranslator::TRANSLATED_CUSTOM_FIELD)
    end
  end

  require_dependency "jobs/base"

  module ::Jobs
    class TranslatorMigrateToAzurePortal < ::Jobs::Onceoff
      def execute_onceoff(args)
        ["translator_client_id", "translator_client_secret"].each do |name|

          DB.exec <<~SQL
          DELETE FROM site_settings WHERE name = '#{name}'
          SQL
        end

        DB.exec <<~SQL
          UPDATE site_settings
          SET name = 'translator_azure_subscription_key'
          WHERE name = 'azure_subscription_key'
        SQL
      end
    end

    class DetectTranslation < ::Jobs::Base
      sidekiq_options retry: false

      def execute(args)
        return if !SiteSetting.translator_enabled

        post = Post.find_by(id: args[:post_id])
        return unless post

        DistributedMutex.synchronize("detect_translation_#{post.id}") do
          "DiscourseTranslator::#{SiteSetting.translator}".constantize.detect(post)
          post.save_custom_fields unless post.custom_fields_clean?
          post.publish_change_to_clients! :revised
        end
      end
    end
  end

  def post_process(post)
    return if !SiteSetting.translator_enabled
    Jobs.enqueue(:detect_translation, post_id: post.id)
  end
  listen_for :post_process

  topic_view_post_custom_fields_allowlister { [::DiscourseTranslator::DETECTED_LANG_CUSTOM_FIELD] }

  require_dependency "post_serializer"
  class ::PostSerializer
    attributes :can_translate

    def can_translate
      return false if !SiteSetting.translator_enabled

      # Skip translations for posts that are manually translated using "discourse-x-multilingial-helper" plugin
      if object.custom_fields["cooked_ru"]
        if I18n.locale == :en
          return false
        elsif I18n.locale == :ru
          return false
        end
      end

      # Skip translations for a specific category is configured
      if SiteSetting.translator_skip_category_id
        category_id_list = SiteSetting.translator_skip_category_id.split(",").collect{ |s| s.to_i }
        if category_id_list.include? category_id
          return false
        end
      end

      if SiteSetting.translator_max_post_length > 0 and object.cooked.length > SiteSetting.translator_max_post_length
        return false
      end

      if SiteSetting.translator_enabled_for_guests or scope.current_user.present?
        # Detect lang if the user is signed in or translation enabled for guests
        detected_lang = post_custom_fields[::DiscourseTranslator::DETECTED_LANG_CUSTOM_FIELD]

        if !detected_lang
          Jobs.enqueue(:detect_translation, post_id: object.id)
          false
        else
          detected_lang != "DiscourseTranslator::#{SiteSetting.translator}::SUPPORTED_LANG".constantize[I18n.locale]
        end
      else
        # Show translation button to guests but ask them to sign in on click
        true
      end
    end

  end

  DiscourseTranslator::Engine.routes.draw do
    post "translate" => "translator#translate"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseTranslator::Engine, at: "translator"
  end
end
