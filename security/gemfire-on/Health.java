import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Base64;

/**
 * Chunk 10c: the GemFire members' healthcheck once their HTTP service is https. compose.yaml's checks
 * speak plain HTTP over bash's /dev/tcp, and the GemFire image has no curl or openssl, but it has a JDK.
 * Compiled once by security/certs/make-certs.sh, run as:
 *
 *   java -cp /certs -Djavax.net.ssl.trustStore=/certs/truststore.p12 ... Health <url> <text the body must contain>
 *
 * Exit 0 = healthy. Credentials: the read-only "monitor" user.
 */
public class Health {
    public static void main(String[] args) throws Exception {
        String auth = "Basic " + Base64.getEncoder().encodeToString("monitor:monitor".getBytes(StandardCharsets.UTF_8));
        HttpResponse<String> res = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build()
                .send(HttpRequest.newBuilder(URI.create(args[0])).timeout(Duration.ofSeconds(2))
                        .header("Authorization", auth).build(), HttpResponse.BodyHandlers.ofString());
        System.exit(res.statusCode() == 200 && res.body().contains(args[1]) ? 0 : 1);
    }
}
