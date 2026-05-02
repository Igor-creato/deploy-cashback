<?php
/**
 * Seed loadtest WooCommerce products via wp-cli.
 * Создаёт N "external" товаров (как у магазинов с кэшбэком), идемпотентно.
 *
 * ENV:
 *   LOADTEST_PRODUCT_COUNT — сколько товаров (default 50).
 *
 * Манифест: wp_options.loadtest_products_manifest (json).
 */

if ( ! defined( 'WP_CLI' ) || ! WP_CLI ) {
	echo "Run via wp-cli\n"; exit( 1 );
}
if ( ! class_exists( 'WC_Product_External' ) ) {
	WP_CLI::error( 'WooCommerce is not active or WC_Product_External not available' );
}

$count = (int) ( getenv( 'LOADTEST_PRODUCT_COUNT' ) ?: 50 );
WP_CLI::log( "Seeding {$count} loadtest products…" );

$networks = array( 'admitad', 'epn', 'cityads' );
$domains  = array( 'aliexpress.com', 'wildberries.ru', 'ozon.ru', 'lamoda.ru', 'mvideo.ru' );

$manifest = array();
$created  = 0;
$existed  = 0;

for ( $i = 1; $i <= $count; $i++ ) {
	$slug = sprintf( 'loadtest-product-%03d', $i );
	$existing = get_page_by_path( $slug, OBJECT, 'product' );
	if ( $existing ) {
		$manifest[] = array(
			'id'     => (int) $existing->ID,
			'slug'   => $slug,
			'domain' => get_post_meta( $existing->ID, '_store_domain', true ),
		);
		$existed++;
		continue;
	}

	$network = $networks[ $i % count( $networks ) ];
	$domain  = $domains[ $i % count( $domains ) ];

	$product = new WC_Product_External();
	$product->set_name( "LoadTest Product #{$i}" );
	$product->set_slug( $slug );
	$product->set_status( 'publish' );
	$product->set_regular_price( (string) ( 100 + $i * 10 ) );
	$product->set_product_url( "https://partner.example/{$network}?subid1=__CLICK_ID__&p={$i}" );
	$product->set_button_text( 'Buy with cashback' );
	$product_id = $product->save();

	if ( ! $product_id ) {
		WP_CLI::warning( "Failed to create {$slug}" );
		continue;
	}

	update_post_meta( $product_id, '_store_domain', $domain );
	update_post_meta( $product_id, '_cashback_display_label', 'Кэшбэк' );
	update_post_meta( $product_id, '_cashback_display_value', 'до 10%' );
	update_post_meta( $product_id, '_cpa_network_slug', $network );
	update_post_meta( $product_id, '_loadtest', '1' );

	$manifest[] = array(
		'id'      => (int) $product_id,
		'slug'    => $slug,
		'domain'  => $domain,
		'network' => $network,
	);
	$created++;
}

update_option( 'loadtest_products_manifest', wp_json_encode( $manifest ), false );

WP_CLI::success( "Products: created={$created}, existed={$existed}, total=" . count( $manifest ) );
