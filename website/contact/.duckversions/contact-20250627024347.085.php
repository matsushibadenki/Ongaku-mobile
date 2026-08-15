// パス: contact.php
<?php
ini_set('display_errors', 1);
ini_set('display_startup_errors', 1);
error_reporting(E_ALL);

require 'libs/recaptcha_vars.php';
require 'libs/validation.php';
require 'libs/recaptcha.php';
require 'libs/send_email.php';
require 'libs/common_vars.php';
require 'libs/html_text.php';

// mbstring関数の設定
if (function_exists('mb_language')) {
    mb_language("uni");
    mb_internal_encoding("UTF-8");
}

// reCAPTCHAキーを変数に設定
$siteKey = V3_SITEKEY;
$secretKey = V3_SECRETKEY;

// フォームがPOSTされた場合の処理
if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    // バリデーションの実行
    $errors = validate_form_data($_POST, 'general');

    // エラーがなかった場合の処理
    if (empty($errors)) {
        // reCAPTCHAの検証
        $recaptcha_response = isset($_POST['g-recaptcha-response']) ? $_POST['g-recaptcha-response'] : '';
        $result = verify_recaptcha($recaptcha_response, $secretKey, $_SERVER['REMOTE_ADDR']);

        // reCAPTCHAの検証が成功した場合の処理
        if ($result['success'] && $result['score'] >= 0.5 && $result['action'] == 'contact') {

            // POSTデータを安全な変数に格納
            $name1 = isset($_POST['name1']) ? trim($_POST['name1']) : '';
            $name2 = isset($_POST['name2']) ? trim($_POST['name2']) : '';
            $name = $name1 . ' ' . $name2;

            $email = isset($_POST['email1']) ? trim($_POST['email1']) : '';
            $companyname = isset($_POST['companyname']) ? trim($_POST['companyname']) : '';
            $department = isset($_POST['department']) ? trim($_POST['department']) : '';
            $position = isset($_POST['position']) ? trim($_POST['position']) : '';
            
            $tel1 = isset($_POST['tel1']) ? trim($_POST['tel1']) : '';
            $tel2 = isset($_POST['tel2']) ? trim($_POST['tel2']) : '';
            $tel3 = isset($_POST['tel3']) ? trim($_POST['tel3']) : '';
            $tel = $tel1 . '-' . $tel2 . '-' . $tel3;
            
            $message = isset($_POST['message']) ? trim($_POST['message']) : '';
            
            $remote_ip = $_SERVER['REMOTE_ADDR'];

            // --------------------------------
            // 1. サイト管理者への通知メール送信
            // --------------------------------
            
            $admin_subject = '【Webサイトお問い合わせ】' . $name . ' 様より';

            $admin_body = "Webサイトの問い合わせフォームから以下の内容で連絡がありました。\n\n";
            $admin_body .= "--------------------------------------------------\n";
            $admin_body .= "お名前： " . $name . "\n";
            $admin_body .= "会社名： " . $companyname . "\n";
            $admin_body .= "部署： " . $department . "\n";
            $admin_body .= "役職： " . $position . "\n";
            $admin_body .= "電話番号： " . $tel . "\n";
            $admin_body .= "E-Mail： " . $email . "\n\n";
            $admin_body .= "メッセージ本文：\n" . $message . "\n";
            $admin_body .= "--------------------------------------------------\n";
            $admin_body .= "送信元IPアドレス： " . $remote_ip . "\n";
            
            // デバッグ情報を追加
            error_log("管理者メール送信開始 - 宛先: " . $to . ", 件名: " . $admin_subject);
            
            // $to と $bcc は common_vars.php で定義
            // 送信元としてユーザーの名前とアドレスを指定することで、メールソフトから直接返信できる
            $is_admin_sent = send_email($to, $admin_subject, $admin_body, $name, $email, $bcc);

            // デバッグ情報を追加
            error_log("管理者メール送信結果: " . ($is_admin_sent ? 'SUCCESS' : 'FAILED'));

            if ($is_admin_sent) {
                echo '<div class="alert alert-success alert-dismissible" role="alert">送信完了いたしました。お問い合わせいただき、ありがとうございました。</div>';

                // --------------------------------
                // 2. ユーザーへの自動返信メール送信
                // --------------------------------

                $reply_subject = '【徳志育舎】お問い合わせありがとうございます';
                $reply_body = get_auto_reply_text($name); // html_text.php からテンプレートを取得

                // 送信元としてサイトの正式名称とアドレスを指定する
                $reply_from_name = '株式会社　徳志育舎';
                $reply_from_email = 'info@ts-ikusya.com'; // common_vars.php の $to と同じ

                // デバッグ情報を追加
                error_log("自動返信メール送信開始 - 宛先: " . $email);

                $is_reply_sent = send_email($email, $reply_subject, $reply_body, $reply_from_name, $reply_from_email);
                
                // デバッグ情報を追加
                error_log("自動返信メール送信結果: " . ($is_reply_sent ? 'SUCCESS' : 'FAILED'));
                
                if ($is_reply_sent) {
                    echo '<div class="alert alert-success alert-dismissible mt-3" role="alert">ご入力いただいたメールアドレスに、確認のメールを自動送信いたしました。</div>';
                } else {
                    echo '<div class="alert alert-warning alert-dismissible mt-3" role="alert">確認メールの送信に失敗しました。ご入力のメールアドレスに誤りがあるか、受信設定をご確認ください。</div>';
                }

            } else {
                // より詳細なエラーメッセージに変更
                echo '<div class="alert alert-danger alert-dismissible mt-3" role="alert">管理者への通知メール送信に失敗しました。サーバーに問題が発生している可能性があります。恐れ入りますが、時間をおいて再度お試しください。</div>';
            }
        } else {
            $recaptcha_errors = isset($result['error-codes']) ? implode(', ', $result['error-codes']) : '不明なエラー';
            echo '<div class="alert alert-danger alert-dismissible" role="alert">reCAPTCHA認証に失敗しました。ボットでない場合は、時間をおいて再度お試しください。 (エラー: ' . htmlspecialchars($recaptcha_errors) . ')</div>';
        }
    } else {
        $errorOutput = '<div class="alert alert-danger alert-dismissible" role="alert">';
        $errorOutput .= '<strong>入力内容にエラーがあります。</strong>';
        $errorOutput .= '<ul>';

        foreach ($errors as $value) {
            $errorOutput .= '<li>' . htmlspecialchars($value) . '</li>';
        }

        $errorOutput .= '</ul>';
        $errorOutput .= '</div>';

        echo $errorOutput;
    }
}
?>