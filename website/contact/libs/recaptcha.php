<?php
function verify_recaptcha($response, $secretKey, $remoteIp = null) {
    $url = 'https://www.google.com/recaptcha/api/siteverify';

    $postData = http_build_query([
        'secret' => $secretKey,
        'response' => $response,
        'remoteip' => $remoteIp
    ]);

    $ch = curl_init($url);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, $postData);
    $result = curl_exec($ch);
    curl_close($ch);

    if ($result === false) {
        return ['success' => false, 'error-codes' => ['curl-error']];
    }

    return json_decode($result, true);
}

?>
