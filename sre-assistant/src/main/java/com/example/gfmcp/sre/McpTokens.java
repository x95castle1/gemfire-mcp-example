package com.example.gfmcp.sre;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Base64;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClient;

/**
 * The Authorization header for each request to the GemFire MCP server (chunk 10).
 *
 * Security off: Basic admin/admin, as in chunk 9.
 *
 * Security on (profile "security"), two identities:
 *   - the APP itself (client credentials of the sre-assistant client): for what no person asked for,
 *     like the MCP handshake at startup (initialize, tools/list). Its service account may only read.
 *   - the PERSON asking a question: their login token (audience: this app) is swapped for an MCP token
 *     in their name with OAuth 2.0 Token Exchange (RFC 8693, Keycloak's "standard token exchange").
 *     Their login token itself is never sent to the MCP server: forwarding a token issued for someone
 *     else is the "token passthrough" the MCP authorization spec forbids.
 */
@Component
public class McpTokens {

    /** An MCP token minted for one person: what the trace panel shows about it. */
    public record Exchanged(String authorization, String user, String scope, Object audience, Instant expiresAt) { }

    private static final String TOKEN_EXCHANGE = "urn:ietf:params:oauth:grant-type:token-exchange";
    private static final String ACCESS_TOKEN = "urn:ietf:params:oauth:token-type:access_token";

    private final boolean security;
    private final String tokenUri;
    private final String clientAuth;
    private final String audience;
    private final String scopes;
    private final String basic;
    // The JDK's HTTP client, on purpose: RestClient.create() picks Reactor Netty when it's on the classpath,
    // and Netty's own DNS resolver answers 127.0.0.1 for EVERY *.localhost name (RFC 6761) without asking
    // Docker's DNS, so keycloak.localhost would never reach the Keycloak container.
    private final RestClient http = RestClient.builder().requestFactory(new JdkClientHttpRequestFactory()).build();

    private volatile String appToken;
    private volatile Instant appTokenExpires = Instant.EPOCH;

    McpTokens(@Value("${gfmcp.security.enabled:false}") boolean security,
              @Value("${gfmcp.oauth.token-uri:}") String tokenUri,
              @Value("${gfmcp.oauth.client-id:}") String clientId,
              @Value("${gfmcp.oauth.client-secret:}") String clientSecret,
              @Value("${gfmcp.oauth.mcp-audience:}") String audience,
              @Value("${gfmcp.oauth.mcp-scopes:}") String scopes,
              @Value("${GF_MCP_AUTH_BASIC_USERNAME:admin}") String user,
              @Value("${GF_MCP_AUTH_BASIC_PASSWORD:admin}") String password) {
        this.security = security;
        this.tokenUri = tokenUri;
        this.clientAuth = "Basic " + b64(clientId + ":" + clientSecret);
        this.audience = audience;
        this.scopes = scopes;
        this.basic = "Basic " + b64(user + ":" + password);
    }

    public boolean securityOn() {
        return security;
    }

    /** The app's own credentials: Basic (security off) or a cached client-credentials token. */
    public String appAuthorization() {
        if (!security) {
            return basic;
        }
        if (appToken == null || Instant.now().isAfter(appTokenExpires)) {
            synchronized (this) {
                if (appToken == null || Instant.now().isAfter(appTokenExpires)) {
                    MultiValueMap<String, String> form = new LinkedMultiValueMap<>();
                    form.add("grant_type", "client_credentials");
                    form.add("scope", "gemfire:read");
                    Map<String, Object> res = post(form);
                    appToken = (String) res.get("access_token");
                    appTokenExpires = Instant.now().plusSeconds(((Number) res.get("expires_in")).longValue() - 30);
                }
            }
        }
        return "Bearer " + appToken;
    }

    /** Swaps a person's login token for an MCP token in their name (RFC 8693). */
    public Exchanged exchange(String userAccessToken, String user) {
        MultiValueMap<String, String> form = new LinkedMultiValueMap<>();
        form.add("grant_type", TOKEN_EXCHANGE);
        form.add("subject_token", userAccessToken);
        form.add("subject_token_type", ACCESS_TOKEN);
        form.add("requested_token_type", ACCESS_TOKEN);
        form.add("audience", audience);
        form.add("scope", scopes);
        Map<String, Object> res = post(form);
        String token = (String) res.get("access_token");
        Map<String, Object> claims = Jwts.claims(token);
        return new Exchanged("Bearer " + token, user, String.valueOf(res.get("scope")), claims.get("aud"),
                Instant.now().plusSeconds(((Number) res.get("expires_in")).longValue()));
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> post(MultiValueMap<String, String> form) {
        return http.post().uri(tokenUri)
                .header("Authorization", clientAuth)
                .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                .body(form)
                .retrieve()
                .body(Map.class);
    }

    private static String b64(String s) {
        return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
    }

    /** Reads (does not verify) a JWT's claims, for display. The MCP server does the verifying. */
    static final class Jwts {
        @SuppressWarnings("unchecked")
        static Map<String, Object> claims(String jwt) {
            try {
                String payload = jwt.split("\\.")[1];
                return new tools.jackson.databind.json.JsonMapper().readValue(Base64.getUrlDecoder().decode(payload), Map.class);
            } catch (Exception e) {
                return Map.of();
            }
        }
    }
}
