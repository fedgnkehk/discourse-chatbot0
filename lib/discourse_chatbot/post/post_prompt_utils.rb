# frozen_string_literal: true
module ::DiscourseChatbot

  class PostPromptUtils < PromptUtils

    def self.create_prompt(opts)
      post_collection = collect_past_interactions(opts[:reply_to_message_or_post_id])
      bot_user_id = opts[:bot_user_id]

      messages = [{ "role": "user", "content":  I18n.t("chatbot.prompt.title", topic_title: post_collection.first.topic.title) }]
      messages << { "role": "user", "content": I18n.t("chatbot.prompt.first_post", username: post_collection.first.topic.first_post.user.username, raw: post_collection.first.topic.first_post.raw) }

      messages += post_collection.reverse.map do |p|
        post_content = p.raw
        post_content.gsub!(/\[quote.*?\](.*?)\[\/quote\]/m, '') if SiteSetting.chatbot_strip_quotes
        role = (p.user_id == bot_user_id ? "assistant" : "user")
        text = (p.user_id == bot_user_id ? "#{p.raw}" : I18n.t("chatbot.prompt.post", username: p.user.username, raw: post_content))
        content = []
        content << {"type": "text", "text": text}
        if p.image_upload_id
          url = Discourse.base_url + Upload.find(p.image_upload_id).url
          content << { "type": "image_url", "image_url": { "url": url } }
        end
        { "role": role, "content": content}
      end

      messages
    end

    def self.collect_past_interactions(message_or_post_id)
      current_post = ::Post.find(message_or_post_id)

      post_collection = []

      accepted_post_types = SiteSetting.chatbot_include_whispers_in_post_history ? ::DiscourseChatbot::POST_TYPES_INC_WHISPERS : ::DiscourseChatbot::POST_TYPES_REGULAR_ONLY

      post_collection << current_post

      collect_amount = SiteSetting.chatbot_max_look_behind

      while post_collection.length < collect_amount do
        if current_post.reply_to_post_number
          linked_post = ::Post.find_by(topic_id: current_post.topic_id, post_number: current_post.reply_to_post_number)
          unless linked_post
            break if current_post.reply_to_post_number == 1
            current_post = ::Post.where(topic_id: current_post.topic_id, post_type: accepted_post_types, deleted_at: nil).where('post_number < ?', current_post.reply_to_post_number).last
            next
          end
          current_post = linked_post
        else
          if current_post.post_number > 1
            current_post = ::Post.where(topic_id: current_post.topic_id, post_type: accepted_post_types, deleted_at: nil).where('post_number < ?', current_post.post_number).last
          else
            break
          end
        end

        post_collection << current_post
      end

      post_collection
    end
  end
end
