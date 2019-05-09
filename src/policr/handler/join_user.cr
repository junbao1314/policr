module Policr
  class JoinUserHandler < Handler
    alias VerifyStatus = Cache::VerifyStatus

    def match(msg)
      all_pass? [
        DB.enable_examine?(msg.chat.id),
        msg.new_chat_members,
      ]
    end

    def handle(msg)
      if members = msg.new_chat_members
        members.select { |m| m.is_bot == false }.each do |member|
          name = bot.get_fullname(member)
          name =~ HalalMessageHandler::ARABIC_CHARACTERS ? kick_halal_with_receipt(msg, member) : torture_action(msg, member)
        end
      end
    end

    def kick_halal_with_receipt(msg, member)
      name = bot.get_fullname(member)
      bot.log "Found a halal '#{name}'"
      if DB.halal_white? member.id
        bot.log "Halal '#{name}' in whitelist, ignored"
        return
      end
      sended_msg = bot.reply msg, "d(`･∀･)b 诶发现一名清真，看我干掉它……"

      if sended_msg
        begin
          bot.kick_chat_member(msg.chat.id, member.id)
          member_id = member.id
          bot.edit_message_text(chat_id: sended_msg.chat.id, message_id: sended_msg.message_id,
            text: "(ﾉ>ω<)ﾉ 已成功丢出去一只清真，真棒！", reply_markup: add_banned_menu(member_id, member.username, true))
          bot.log "Halal '#{name}' has been banned"
        rescue ex : TelegramBot::APIException
          bot.edit_message_text(chat_id: sended_msg.chat.id, message_id: sended_msg.message_id,
            text: "╰(〒皿〒)╯ 啥情况，这枚清真移除失败了。")
          _, reason = bot.get_error_code_with_reason(ex)
          bot.log "Halal '#{name}' banned failure, reason: #{reason}"
        end
      end
    end

    def add_banned_menu(user_id, username, is_halal = false)
      markup = Markup.new
      markup << Button.new(text: "解除封禁", callback_data: "BanedMenu:#{user_id}:#{username}:unban")
      markup << Button.new(text: "加入白名单", callback_data: "BanedMenu:#{user_id}:#{username}:whitelist") if is_halal
      markup
    end

    def torture_action(msg, member)
      Cache.verify_init(member.id)
      default =
        {
          1,
          "你认为自己能不能进来？",
          [
            "是的，我觉得可以",
            "不能，请踢掉我吧",
          ],
        }
      custom = DB.custom(msg.chat.id)

      _, title, answers = custom ? custom : default

      # 禁言用户
      bot.restrict_chat_member(msg.chat.id, member.id, can_send_messages: false)

      torture_sec = DB.get_torture_sec(msg.chat.id, DEFAULT_TORTURE_SEC)
      name = bot.get_fullname(member)
      bot.log "Start to torture '#{name}'"
      question = "请在 #{torture_sec} 秒内确认「#{title}」以通过验证"
      reply_id = msg.message_id
      member_id = member.id.to_s
      member_username = member.username

      btn = ->(text : String, chooese_id : Int32) {
        Button.new(text: text, callback_data: "Torture:#{member_id}:#{member_username}:#{chooese_id}")
      }
      markup = Markup.new
      answers.each_with_index { |answer, i| markup << [btn.call(answer, i + 1)] }
      markup << [btn.call("人工通过", 0), btn.call("人工封禁", -1)]
      sended_msg = bot.send_message(msg.chat.id, question, reply_to_message_id: reply_id, reply_markup: markup)

      ban_task = ->(message_id : Int32) {
        if Cache.verify?(member.id) == VerifyStatus::Init
          bot.log "User '#{name}' torture time expired and has been banned"
          Cache.verify_slowed(member.id)
          unverified_with_receipt(msg.chat.id, message_id, member.id, member.username)
        end
      }

      ban_timer = ->(message_id : Int32) { Schedule.after(torture_sec.seconds) { ban_task.call(message_id) } }
      if sended_msg && (message_id = sended_msg.message_id)
        ban_timer.call(message_id)
      end
    end

    def unverified_with_receipt(chat_id, message_id, user_id, username, admin = false)
      Cache.verify_status_clear user_id
      bot.log "Username '#{username}' has not been verified and has been banned"
      begin
        bot.kick_chat_member(chat_id, user_id)
      rescue ex : TelegramBot::APIException
        text = "踢不掉他诶（自己想想什么原因？）……"
        bot.edit_message_text(chat_id: chat_id, message_id: message_id,
          text: text)
      else
        text = "(〒︿〒) 他没能挺过这一关，永久的离开了我们。"
        text = "(|||ﾟдﾟ) 太残忍了，独裁者直接干掉了他。" if admin
        bot.edit_message_text(chat_id: chat_id, message_id: message_id,
          text: text, reply_markup: add_banned_menu(user_id, username))
      end
    end
  end
end
