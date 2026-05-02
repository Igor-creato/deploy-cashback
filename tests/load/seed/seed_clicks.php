<?php
/**
 * Seed wp_cashback_click_log records — needed for webhook scenarios
 * (worker матчит постбэк по click_id → user_id).
 *
 * Идемпотентно: повторный запуск пропускает существующие click_id.
 *
 * ENV:
 *   LOADTEST_CLICK_COUNT — сколько кликов создавать (default 200).
 *
 * Манифест: wp_options.loadtest_clicks_manifest (json), формат:
 *   [{"click_id":"<32hex>", "user_id": <int>, "product_id": <int>}, ...]
 */

if ( ! defined( 'WP_CLI' ) || ! WP_CLI ) {
	echo "Run via wp-cli\n"; exit( 1 );
}

global $wpdb;
$table = $wpdb->prefix . 'cashback_click_log';

$users_json = get_option( 'loadtest_users_manifest', '[]' );
$prods_json = get_option( 'loadtest_products_manifest', '[]' );
$users = json_decode( $users_json, true );
$prods = json_decode( $prods_json, true );

if ( ! is_array( $users ) || ! count( $users ) ) {
	WP_CLI::error( 'No users manifest. Run seed_users.php first.' );
}
if ( ! is_array( $prods ) || ! count( $prods ) ) {
	WP_CLI::error( 'No products manifest. Run seed_products.php first.' );
}

$count = (int) ( getenv( 'LOADTEST_CLICK_COUNT' ) ?: 200 );
WP_CLI::log( "Seeding {$count} loadtest clicks…" );

/**
 * UUID v7-ish: timestamp_ms (48 bit) + random (80 bit), hex without dashes.
 * 32 hex chars to match CHAR(32) ascii_bin schema of click_log.click_id.
 */
function loadtest_uuid7_hex(): string {
	$ts = (int) ( microtime( true ) * 1000 );
	$ts_hex = str_pad( dechex( $ts ), 12, '0', STR_PAD_LEFT );
	$rand = bin2hex( random_bytes( 10 ) );
	// version 7 nibble
	return $ts_hex . '7' . substr( $rand, 0, 3 ) . substr( $rand, 3 );
}

$manifest = array();
$created  = 0;
$skipped  = 0;
$now      = current_time( 'mysql' );

for ( $i = 0; $i < $count; $i++ ) {
	$user = $users[ $i % count( $users ) ];
	$prod = $prods[ $i % count( $prods ) ];

	$click_id = loadtest_uuid7_hex();
	$network  = $prod['network'] ?? 'admitad';
	$aff_url  = sprintf( 'https://partner.example/%s?subid1=%s&subid2=%d', $network, $click_id, $user['id'] );

	$res = $wpdb->query( $wpdb->prepare(
		"INSERT IGNORE INTO `{$table}`
		 (click_id, user_id, product_id, cpa_network, affiliate_url, ip_address, spam_click, created_at)
		 VALUES (%s, %d, %d, %s, %s, %s, 0, %s)",
		$click_id,
		(int) $user['id'],
		(int) $prod['id'],
		$network,
		$aff_url,
		'127.0.0.1',
		$now
	) );

	if ( $res === false ) {
		WP_CLI::warning( 'Insert failed: ' . $wpdb->last_error );
		continue;
	}
	if ( $res === 0 ) {
		$skipped++;
		continue;
	}

	$manifest[] = array(
		'click_id'   => $click_id,
		'user_id'    => (int) $user['id'],
		'product_id' => (int) $prod['id'],
		'network'    => $network,
	);
	$created++;
}

update_option( 'loadtest_clicks_manifest', wp_json_encode( $manifest ), false );

WP_CLI::success( "Clicks: created={$created}, skipped={$skipped}, manifest=" . count( $manifest ) );
