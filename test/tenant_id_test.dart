import 'package:cognihire/core/tenancy/tenant_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TenantId construction', () {
    test('wraps a non-empty value', () {
      final id = TenantId('org-123');
      expect(id.value, 'org-123');
    });

    test('rejects an empty value', () {
      expect(() => TenantId(''), throwsArgumentError);
    });

    test('rejects leading/trailing whitespace', () {
      expect(() => TenantId(' org-123'), throwsArgumentError);
      expect(() => TenantId('org-123 '), throwsArgumentError);
    });
  });

  group('TenantId equality', () {
    test('two ids with the same value are equal', () {
      expect(TenantId('org-123'), TenantId('org-123'));
    });

    test('two ids with different values are not equal', () {
      expect(TenantId('org-123'), isNot(TenantId('org-456')));
    });

    test('equal ids share a hashCode', () {
      expect(TenantId('org-123').hashCode, TenantId('org-123').hashCode);
    });

    test('works as a Set/Map key', () {
      final seen = <TenantId>{TenantId('org-123'), TenantId('org-123')};
      expect(seen, hasLength(1));
    });
  });

  group('TenantId serialization', () {
    test('toJson returns the raw value', () {
      expect(TenantId('org-123').toJson(), 'org-123');
    });

    test('fromJson round-trips through toJson', () {
      final original = TenantId('org-123');
      final decoded = TenantId.fromJson(original.toJson());
      expect(decoded, original);
    });

    test('fromJson rejects a non-String value', () {
      expect(() => TenantId.fromJson(123), throwsArgumentError);
      expect(() => TenantId.fromJson(null), throwsArgumentError);
    });

    test('fromJson applies the same validation as the constructor', () {
      expect(() => TenantId.fromJson(''), throwsArgumentError);
    });
  });

  group('TenantId toString', () {
    test('renders the raw value, not a wrapper description', () {
      expect(TenantId('org-123').toString(), 'org-123');
    });
  });
}
