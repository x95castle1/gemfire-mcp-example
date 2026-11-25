package com.example.gfmcp.sre;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.http.converter.FormHttpMessageConverter;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClientManager;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClientProviderBuilder;
import org.springframework.security.oauth2.client.endpoint.RestClientAuthorizationCodeTokenResponseClient;
import org.springframework.security.oauth2.client.endpoint.RestClientRefreshTokenTokenResponseClient;
import org.springframework.security.oauth2.client.http.OAuth2ErrorResponseErrorHandler;
import org.springframework.security.oauth2.client.oidc.web.logout.OidcClientInitiatedLogoutSuccessHandler;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.web.DefaultOAuth2AuthorizationRequestResolver;
import org.springframework.security.oauth2.client.web.DefaultOAuth2AuthorizedClientManager;
import org.springframework.security.oauth2.client.web.OAuth2AuthorizationRequestCustomizers;
import org.springframework.security.oauth2.client.web.OAuth2AuthorizedClientRepository;
import org.springframework.security.oauth2.core.http.converter.OAuth2AccessTokenResponseHttpMessageConverter;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.web.client.RestClient;

/**
 * Chunk 10b. Two configurations, picked by the Spring profile:
 *   - default (security off): every page open, as in chunk 9
 *   - "security": log in through Keycloak first; /actuator stays open for the healthcheck and Prometheus
 *
 * Gotcha: Spring Security's token clients build their own RestClient, which picks Reactor Netty when
 * it's on the classpath (Spring AI brings it). Netty's DNS resolver answers 127.0.0.1 for every
 * *.localhost name (RFC 6761) without asking Docker's DNS, so keycloak.localhost never reached Keycloak
 * and the login ended at /login?error with nothing in the log. tokenClient() uses the JDK HTTP client.
 */
@Configuration
class SecurityConfig {

    @Bean
    @Profile("!security")
    SecurityFilterChain open(HttpSecurity http) throws Exception {
        return http
                .authorizeHttpRequests(a -> a.anyRequest().permitAll())
                .csrf(c -> c.disable())
                .build();
    }

    @Bean
    @Profile("security")
    SecurityFilterChain login(HttpSecurity http, ClientRegistrationRepository registrations) throws Exception {
        // Authorization code flow WITH PKCE: the browser never sees a reusable secret, and a stolen
        // authorization code is useless without the verifier this app kept.
        DefaultOAuth2AuthorizationRequestResolver resolver =
                new DefaultOAuth2AuthorizationRequestResolver(registrations, "/oauth2/authorization");
        resolver.setAuthorizationRequestCustomizer(OAuth2AuthorizationRequestCustomizers.withPkce());

        // Logout ends the Keycloak session too (RP-initiated logout), then comes back here
        OidcClientInitiatedLogoutSuccessHandler logout = new OidcClientInitiatedLogoutSuccessHandler(registrations);
        logout.setPostLogoutRedirectUri("{baseUrl}/");

        return http
                .authorizeHttpRequests(a -> a
                        .requestMatchers("/actuator/**").permitAll()
                        .anyRequest().authenticated())
                .oauth2Login(o -> o
                        .authorizationEndpoint(e -> e.authorizationRequestResolver(resolver))
                        .tokenEndpoint(t -> t.accessTokenResponseClient(codeClient())))
                .logout(l -> l.logoutSuccessHandler(logout))
                // The page sends the CSRF token from the XSRF-TOKEN cookie as X-XSRF-TOKEN (static/index.html)
                .csrf(c -> c.spa())
                .build();
    }

    /** Hands out the logged-in person's access token, refreshing it with the refresh token when it expires. */
    @Bean
    @Profile("security")
    OAuth2AuthorizedClientManager authorizedClientManager(ClientRegistrationRepository registrations,
                                                          OAuth2AuthorizedClientRepository clients) {
        DefaultOAuth2AuthorizedClientManager manager = new DefaultOAuth2AuthorizedClientManager(registrations, clients);
        manager.setAuthorizedClientProvider(OAuth2AuthorizedClientProviderBuilder.builder()
                .authorizationCode()
                .refreshToken(r -> r.accessTokenResponseClient(refreshClient()))
                .build());
        return manager;
    }

    private static RestClientAuthorizationCodeTokenResponseClient codeClient() {
        RestClientAuthorizationCodeTokenResponseClient c = new RestClientAuthorizationCodeTokenResponseClient();
        c.setRestClient(tokenClient());
        return c;
    }

    private static RestClientRefreshTokenTokenResponseClient refreshClient() {
        RestClientRefreshTokenTokenResponseClient c = new RestClientRefreshTokenTokenResponseClient();
        c.setRestClient(tokenClient());
        return c;
    }

    /** What Spring Security's default token RestClient is, on the JDK HTTP client instead of Netty. */
    private static RestClient tokenClient() {
        return RestClient.builder()
                .requestFactory(new JdkClientHttpRequestFactory())
                .messageConverters(m -> {
                    m.clear();
                    m.add(new FormHttpMessageConverter());
                    m.add(new OAuth2AccessTokenResponseHttpMessageConverter());
                })
                .defaultStatusHandler(new OAuth2ErrorResponseErrorHandler())
                .build();
    }
}
