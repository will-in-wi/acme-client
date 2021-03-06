require 'spec_helper'

describe Acme::Client do
  let(:connection_options) { {} }
  let(:unregistered_client) { Acme::Client.new(private_key: generate_private_key, connection_options: connection_options) }

  let(:registered_client) do
    client = Acme::Client.new(private_key: generate_private_key)
    client.register(contact: 'mailto:mail@example.com')
    client
  end

  let(:active_client) do
    client = Acme::Client.new(private_key: generate_private_key)
    registration = client.register(contact: 'mailto:mail@example.com')
    registration.agree_terms
    client
  end

  context 'generic errors' do
    it 'raises on error with a non jose+json body', vcr: { cassette_name: 'non_json' } do
      expect {
        active_client.agree_terms
      }.to raise_error(Acme::Client::Error)
    end
  end

  context 'connection_options' do
    let(:connection_options) { { request: { open_timeout: 5, timeout: 5 } } }

    before(:each) do
      stub_request(:head, 'http://127.0.0.1:4000/acme/new-reg').with(
        headers: { 'Accept' => '*/*', 'User-Agent' => 'Faraday v0.9.2' }
      ).to_timeout
    end

    it 'passes the connection options to faraday' do
      expect(unregistered_client.connection.options.open_timeout).to eq(5)
      expect(unregistered_client.connection.options.timeout).to eq(5)
    end

    it 'fails with a timeout' do
      expect {
        unregistered_client.register(contact: %w(mailto:cert-admin@example.com tel:+15145552222))
      }.to raise_error(Acme::Client::Error::Timeout)
    end
  end

  context '#register' do
    it 'register successfully', vcr: { cassette_name: 'register_success' } do
      expect {
        registration = unregistered_client.register(contact: %w(mailto:cert-admin@example.com tel:+15145552222))
        expect(registration).to be_a(Acme::Client::Resources::Registration)
      }.to_not raise_error
    end

    it 'fail to register with an invalid contact', vcr: { cassette_name: 'register_invalid_contact' } do
      expect {
        unregistered_client.register(contact: %w(mailto:not-valid))
      }.to raise_error(Acme::Client::Error, /not a valid e-mail address/)
    end

    it 'fail to register a key that is already registered', vcr: { cassette_name: 'register_duplicate_failure' } do
      expect {
        registered_client.register(contact: %w(mailto:cert-admin@example.com tel:+15145552222))
      }.to raise_error(Acme::Client::Error, /Registration key is already in use/)
    end
  end

  context '#authorize' do
    it 'succeed', vcr: { cassette_name: 'authorize_success' } do
      expect {
        registration = active_client.authorize(domain: 'example.org')
        expect(registration).to be_a(Acme::Client::Resources::Authorization)
      }.to_not raise_error
    end

    it 'fail when the client has not yet agree to the tos', vcr: { cassette_name: 'authorize_fail_tos' } do
      expect {
        registered_client.authorize(domain: 'example.org')
      }.to raise_error(Acme::Client::Error, /Must agree to subscriber agreement before any further actions/)
    end

    it 'fail when the client receive an error without a type', vcr: { cassette_name: 'authorize_fail_server_error' } do
      expect {
        registered_client.authorize(domain: 'example.org')
      }.to raise_error(Acme::Client::Error)
    end

    it 'fail when the domain is not valid', vcr: { cassette_name: 'authorize_invalid_domain' } do
      expect {
        active_client.authorize(domain: 'notadomain.invalid')
      }.to raise_error(Acme::Client::Error, /Error creating new authz/)
    end
  end

  context '#new_certificate' do
    let(:domain) { 'test.example.org' }
    let(:private_key) { generate_private_key }
    let(:client) { Acme::Client.new(private_key: private_key) }
    let(:csr) { generate_csr(domain, generate_private_key) }
    let(:request) { Acme::Client::CertificateRequest.new(common_name: domain, private_key: generate_private_key) }

    before(:each) do
      registration = client.register(contact: 'mailto:info@example.com')
      registration.agree_terms
      authorization = client.authorize(domain: domain)
      http01 = authorization.http01

      serve_once(http01.file_content) do
        http01.request_verification
        retry_until(condition: lambda { http01.status != 'pending' }) do
          http01.verify_status
        end
      end
    end

    it 'retrieve a new certificate successfully', vcr: { cassette_name: 'new_certificate_success' } do
      certificate = nil

      expect {
        certificate = client.new_certificate(csr)
      }.to_not raise_error

      expect(certificate).to be_a(Acme::Client::Certificate)
      expect(certificate.common_name).to eq(domain)
      expect(certificate.x509).to be_a(OpenSSL::X509::Certificate)
      expect(certificate.x509_chain).not_to be_empty
      expect(certificate.x509_chain).to contain_exactly(a_kind_of(OpenSSL::X509::Certificate), a_kind_of(OpenSSL::X509::Certificate))
      expect(certificate.url).to eq('http://127.0.0.1:4000/acme/cert/ff87f2112cf6596eddb5df39113701b1572a')
    end

    it 'retrieve a new certificate successfully using a CertificateRequest', vcr: { cassette_name: 'new_certificate_success' } do
      certificate = nil

      expect {
        certificate = client.new_certificate(request)
      }.to_not raise_error

      expect(certificate).to be_a(Acme::Client::Certificate)
      expect(certificate.common_name).to eq(domain)
      expect(certificate.x509).to be_a(OpenSSL::X509::Certificate)
      expect(certificate.x509_chain).not_to be_empty
      expect(certificate.x509_chain).to contain_exactly(a_kind_of(OpenSSL::X509::Certificate), a_kind_of(OpenSSL::X509::Certificate))
      expect(certificate.x509_fullchain.first).to be(certificate.x509)
      expect(certificate.url).to eq('http://127.0.0.1:4000/acme/cert/ff87f2112cf6596eddb5df39113701b1572a')
    end
  end

  context '#revoke_certificate' do
    let(:domain) { 'test.example.org' }
    let(:account_private_key) { generate_private_key }
    let(:certificate_private_key) { generate_private_key }

    let(:client) { Acme::Client.new(private_key: account_private_key) }
    let(:request) { Acme::Client::CertificateRequest.new(common_name: domain, private_key: certificate_private_key) }
    let(:certificate) { client.new_certificate(request) }

    let(:bad_client) { Acme::Client.new(private_key: generate_private_key) }

    before(:each) do
      registration = client.register(contact: 'mailto:info@example.com')
      registration.agree_terms
      authorization = client.authorize(domain: domain)
      http01 = authorization.http01

      serve_once(http01.file_content) do
        http01.request_verification
        retry_until(condition: lambda { http01.status != 'pending' }) do
          http01.verify_status
        end
      end
    end

    it 'revoke a certificate successfully with the account key', vcr: { cassette_name: 'revoke_certificate_success_account_key' } do
      expect { client.revoke_certificate(certificate) }.to_not raise_error
    end

    it 'revoke a certificate successfully with the certificate key', vcr: { cassette_name: 'revoke_certificate_success_certificate_key' } do
      expect { Acme::Client.revoke_certificate(certificate, private_key: certificate_private_key) }.to_not raise_error
    end

    it 'revoke a certificate fail when using an unknown key', vcr: { cassette_name: 'revoke_certificate_bad_key' } do
      expect { bad_client.revoke_certificate(certificate) }.to raise_error(Acme::Client::Error::Unauthorized)
    end
  end

  context '#challenge_from_hash' do
    let(:challenge_hash) do
      { 'token' => 'some-token', 'uri' => '/some-uri' }
    end

    let(:client) { Acme::Client.new(private_key: 'fake-key') }
    let(:http01) { Acme::Client::Resources::Challenges::HTTP01 }
    let(:dns01) { Acme::Client::Resources::Challenges::DNS01 }
    let(:tls_sni01) { Acme::Client::Resources::Challenges::TLSSNI01 }

    it 'returns an HTTP01 challenge object with the specified parameters' do
      challenge = client.challenge_from_hash(challenge_hash.merge('type' => http01::CHALLENGE_TYPE))

      expect(challenge).to be_a(http01)
      expect(challenge.uri).to eq challenge_hash['uri']
      expect(challenge.token).to eq challenge_hash['token']
    end

    it 'returns a DNS01 challenge object with the specified parameters' do
      challenge = client.challenge_from_hash(challenge_hash.merge('type' => dns01::CHALLENGE_TYPE))

      expect(challenge).to be_a(dns01)
      expect(challenge.uri).to eq challenge_hash['uri']
      expect(challenge.token).to eq challenge_hash['token']
    end

    it 'returns an TLSSNI01 challenge object with the specified parameters' do
      challenge = client.challenge_from_hash(challenge_hash.merge('type' => tls_sni01::CHALLENGE_TYPE))

      expect(challenge).to be_a(tls_sni01)
      expect(challenge.uri).to eq challenge_hash['uri']
      expect(challenge.token).to eq challenge_hash['token']
    end

    it 'returns nil if an unsupported challenge type is provided' do
      expect {
        client.challenge_from_hash(challenge_hash.merge('type' => 'nope'))
      }.to raise_error(RuntimeError, 'Unsupported resource type')
    end
  end
end
