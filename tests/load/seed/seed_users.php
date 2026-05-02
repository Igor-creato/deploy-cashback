<?php
/**
 * Seed loadtest users via wp-cli `wp eval-file`.
 * Идемпотентно: повторный запуск пропускает уже существующих.
 *
 * ENV:
 *   LOADTEST_PASS         — пароль для всех тестовых юзеров.
 *   LOADTEST_USER_COUNT   — сколько создавать (default 200).
 *
 * Сохраняет manifest в wp_options.loadtest_users_manifest (json).
 */

if ( ! defined( 'WP_CLI' ) || ! WP_CLI ) {
	echo "Run via wp-cli: wp eval-file seed_users.php\n";
	exit( 1 );
}

$pass  = getenv( 'LOADTEST_PASS' ) ?: '';
$count = (int) ( getenv( 'LOADTEST_USER_COUNT' ) ?: 200 );

if ( $pass === '' ) {
	WP_CLI::error( 'LOADTEST_PASS env is required' );
}
if ( strlen( $pass ) < 12 ) {
	WP_CLI::error( 'LOADTEST_PASS too short (>= 12 chars required)' );
}

WP_CLI::log( "Seeding {$count} loadtest users…" );

$manifest = array();
$created  = 0;
$existed  = 0;

for ( $i = 1; $i <= $count; $i++ ) {
	$login = sprintf( 'loadtest_user_%03d', $i );
	$email = sprintf( 'loadtest+%03d@invalid.local', $i );

	$user = get_user_by( 'login', $login );
	if ( $user ) {
		$manifest[] = array(
			'id'    => (int) $user->ID,
			'login' => $login,
		);
		$existed++;
		continue;
	}

	$user_id = wp_insert_user(
		array(
			'user_login'   => $login,
			'user_pass'    => $pass,
			'user_email'   => $email,
			'display_name' => "LoadTest #{$i}",
			'role'         => 'customer',
		)
	);

	if ( is_wp_error( $user_id ) ) {
		WP_CLI::warning( "Failed to create {$login}: " . $user_id->get_error_message() );
		continue;
	}

	$manifest[] = array(
		'id'    => (int) $user_id,
		'login' => $login,
	);
	$created++;
}

update_option( 'loadtest_users_manifest', wp_json_encode( $manifest ), false );

WP_CLI::success( "Users: created={$created}, existed={$existed}, total=" . count( $manifest ) );
